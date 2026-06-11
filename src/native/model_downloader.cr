require "http/client"
require "json"
require "file_utils"
require "./errors"

module Llamero::Native
  # Downloads model artifacts from the HuggingFace Hub into a local cache so
  # the native bridge always loads from a directory.
  #
  # Llamero owns the download path (rather than the Swift bridge) for two
  # reasons: it keeps full control of caching/progress/auth in Crystal, and
  # the Swift HuggingFace client routes work through the main dispatch queue,
  # which deadlocks inside a non-Swift host process.
  #
  # Models are cached under `~/.llamero/models/<org>--<name>/` with a
  # `.llamero-complete` marker written only after every file lands. Set
  # `HF_TOKEN` (or `HUGGING_FACE_HUB_TOKEN`) for gated models such as Gemma.
  class ModelDownloader
    DEFAULT_ENDPOINT = "https://huggingface.co"

    # Model files the runtime needs: weights, config, and tokenizer data.
    WANTED = [
      /^config\.json$/,
      /^generation_config\.json$/,
      /\.safetensors$/,
      /\.safetensors\.index\.json$/,
      /^tokenizer\.json$/,
      /^tokenizer\.model$/,
      /^tokenizer_config\.json$/,
      /^special_tokens_map\.json$/,
      /^vocab\.json$/,
      /^merges\.txt$/,
      /^chat_template\.(jinja|json)$/,
    ]

    COMPLETE_MARKER = ".llamero-complete"
    MAX_REDIRECTS   = 5

    getter cache_dir : Path

    def initialize(
      cache_dir : Path | String = Path.home.join(".llamero", "models"),
      @endpoint : String = DEFAULT_ENDPOINT,
      @token : String? = ENV["HF_TOKEN"]? || ENV["HUGGING_FACE_HUB_TOKEN"]?
    )
      @cache_dir = Path[cache_dir].expand
    end

    # Local directory a model id resolves to (whether or not it is cached).
    def model_dir(model_id : String) : Path
      @cache_dir.join(model_id.gsub('/', "--"))
    end

    def cached?(model_id : String) : Bool
      File.exists?(model_dir(model_id).join(COMPLETE_MARKER))
    end

    # Returns the local directory for the model, downloading it first when
    # not cached. Progress is reported as a fraction (0.0..1.0) of total
    # bytes across all files.
    def resolve(model_id : String, &progress : Float64 -> Nil) : Path
      dir = model_dir(model_id)
      return dir if cached?(model_id)

      files = list_model_files(model_id)
      wanted = files.select { |file| WANTED.any?(&.matches?(file.name)) }
      if wanted.none? { |file| file.name == "config.json" }
        raise ModelUnavailableError.new(
          "Model #{model_id} has no config.json on the HuggingFace Hub - is the id correct?"
        )
      end

      FileUtils.mkdir_p(dir.to_s)
      total_bytes = wanted.sum(&.size)
      done_bytes = 0_i64

      wanted.each do |file|
        download_file(model_id, file.name, dir.join(file.name)) do |chunk_bytes|
          done_bytes += chunk_bytes
          progress.call(total_bytes > 0 ? done_bytes.to_f / total_bytes : 0.0)
        end
      end

      File.write(dir.join(COMPLETE_MARKER).to_s, Time.utc.to_rfc3339)
      dir
    end

    def resolve(model_id : String) : Path
      resolve(model_id) { }
    end

    private record ModelFile, name : String, size : Int64

    # Lists repo files (with sizes) via the Hub API.
    private def list_model_files(model_id : String) : Array(ModelFile)
      response = get_following_redirects("#{@endpoint}/api/models/#{model_id}?blobs=true")
      unless response.status.success?
        raise ModelUnavailableError.new(
          "Failed to list files for #{model_id}: HTTP #{response.status_code} " \
          "#{response.status_code == 401 || response.status_code == 403 ? "(gated model? set HF_TOKEN)" : ""}".strip
        )
      end

      siblings = JSON.parse(response.body)["siblings"]?.try(&.as_a) || [] of JSON::Any
      siblings.map do |sibling|
        ModelFile.new(
          name: sibling["rfilename"].as_s,
          size: sibling["size"]?.try(&.as_i64) || 0_i64
        )
      end
    end

    private def download_file(model_id : String, file_name : String, destination : Path, &on_bytes : Int64 -> Nil) : Nil
      partial = Path["#{destination}.partial"]
      url = "#{@endpoint}/#{model_id}/resolve/main/#{file_name}"

      get_following_redirects(url) do |response|
        unless response.status.success?
          raise ModelUnavailableError.new("Failed to download #{file_name} for #{model_id}: HTTP #{response.status_code}")
        end

        File.open(partial.to_s, "w") do |file|
          buffer = Bytes.new(256 * 1024)
          body = response.body_io
          while (read = body.read(buffer)) > 0
            file.write(buffer[0, read])
            on_bytes.call(read.to_i64)
          end
        end
      end

      FileUtils.mv(partial.to_s, destination.to_s)
    end

    # HTTP::Client does not follow redirects; the Hub redirects /resolve/
    # URLs to a CDN, so we follow manually. Auth is only sent to the Hub
    # endpoint, never to the redirect target.
    private def get_following_redirects(url : String) : HTTP::Client::Response
      MAX_REDIRECTS.times do
        response = HTTP::Client.get(url, headers: headers_for(url))
        if redirect = redirect_location(response, url)
          url = redirect
          next
        end
        return response
      end
      raise ModelUnavailableError.new("Too many redirects fetching #{url}")
    end

    private def get_following_redirects(url : String, &block : HTTP::Client::Response -> Nil) : Nil
      MAX_REDIRECTS.times do
        done = false
        HTTP::Client.get(url, headers: headers_for(url)) do |response|
          if redirect = redirect_location(response, url)
            url = redirect
          else
            block.call(response)
            done = true
          end
        end
        return if done
      end
      raise ModelUnavailableError.new("Too many redirects fetching #{url}")
    end

    private def redirect_location(response : HTTP::Client::Response, current_url : String) : String?
      return nil unless {301, 302, 303, 307, 308}.includes?(response.status_code)
      location = response.headers["Location"]? || return nil
      location.starts_with?("http") ? location : URI.parse(current_url).resolve(location).to_s
    end

    private def headers_for(url : String) : HTTP::Headers
      headers = HTTP::Headers{"User-Agent" => "llamero/#{Llamero::VERSION}"}
      if (token = @token) && url.starts_with?(@endpoint)
        headers["Authorization"] = "Bearer #{token}"
      end
      headers
    end
  end
end
