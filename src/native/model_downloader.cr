require "http/client"
require "json"
require "file_utils"
require "../config/storage"
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
  # Models are cached under the configured storage root with a completion
  # marker written only after every file lands. Set
  # `HF_TOKEN` (or `HUGGING_FACE_HUB_TOKEN`) for gated models such as Gemma.
  #
  # A model id may pin a Hub revision (git sha, tag, or branch) with an `@`
  # suffix: `mlx-community/gemma-4-e2b-it-4bit@2c3e5074...`. Pinned revisions
  # cache separately from the moving default branch. Pin when an upstream
  # repo re-uploads a conversion whose layout the bundled loader cannot read
  # yet — the checkpoint you tested stays the checkpoint you get.
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

    COMPLETE_MARKER = "#{Llamero::Storage::DEFAULT_BASENAME}-complete"
    MAX_REDIRECTS   = 5

    getter cache_dir : Path

    def initialize(
      cache_dir : Path | String = Llamero::Storage.models_dir,
      @endpoint : String = DEFAULT_ENDPOINT,
      @token : String? = ENV["HF_TOKEN"]? || ENV["HUGGING_FACE_HUB_TOKEN"]?,
    )
      @cache_dir = Path[cache_dir].expand
    end

    # Splits `org/name@revision` into the repo id and the revision (nil when
    # no pin is present).
    def self.split_revision(model_id : String) : {String, String?}
      if at = model_id.index('@')
        {model_id[0...at], model_id[(at + 1)..]}
      else
        {model_id, nil}
      end
    end

    # Local directory a model id resolves to (whether or not it is cached).
    # Pinned revisions cache separately: `org--name@revision`.
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

      repo_id, revision = ModelDownloader.split_revision(model_id)
      files = list_model_files(repo_id, revision)
      wanted = files.select { |file| WANTED.any?(&.matches?(file.name)) }
      if wanted.none? { |file| file.name == "config.json" }
        raise ModelUnavailableError.new(
          "Model #{model_id} has no config.json on the HuggingFace Hub - is the id correct?"
        )
      end
      if wanted.none? { |file| file.name.ends_with?(".safetensors") }
        raise ModelUnavailableError.new(
          "Model #{model_id} has no .safetensors weights on the Hugging Face Hub. " \
          "llamero loads MLX-format checkpoints (config.json + safetensors) - use an " \
          "mlx-community/* conversion (https://huggingface.co/mlx-community) or convert " \
          "one with `mlx_lm.convert`."
        )
      end

      FileUtils.mkdir_p(dir.to_s)
      total_bytes = wanted.sum(&.size)
      done_bytes = 0_i64

      wanted.each do |file|
        download_file(repo_id, revision, file.name, dir.join(file.name)) do |chunk_bytes|
          done_bytes += chunk_bytes
          progress.call(total_bytes > 0 ? done_bytes.to_f / total_bytes : 0.0)
        end
      end

      complete_gemma3_text_config(dir)
      File.write(dir.join(COMPLETE_MARKER).to_s, Time.utc.to_rfc3339)
      dir
    end

    def resolve(model_id : String) : Path
      resolve(model_id) { }
    end

    private record ModelFile, name : String, size : Int64

    # Restores text_config fields the 4-bit converter drops from multimodal
    # Gemma 3 checkpoints (it omits values equal to transformers class
    # defaults, and the Swift loader then falls back to 1B geometry). Only
    # genuinely missing fields are added, keyed on the checkpoint's own
    # hidden_size. See development_docs/gemma3_4b_load_fix.md.
    GEMMA3_TEXT_GEOMETRY = {
      1152 => {num_attention_heads: 4, num_key_value_heads: 1, head_dim: 256},  # 1B
      2560 => {num_attention_heads: 8, num_key_value_heads: 4, head_dim: 256},  # 4B
      3840 => {num_attention_heads: 16, num_key_value_heads: 8, head_dim: 256}, # 12B
      5376 => {num_attention_heads: 32, num_key_value_heads: 16, head_dim: 256}, # 27B
    }

    private def complete_gemma3_text_config(dir : Path) : Nil
      config_path = dir.join("config.json")
      return unless File.exists?(config_path.to_s)
      config = JSON.parse(File.read(config_path.to_s)).as_h? || return
      model_type = config["model_type"]?.try(&.as_s?)
      return unless model_type.in?("gemma3", "gemma3_text")
      text_config = config["text_config"]?.try(&.as_h?) || return
      hidden_size = text_config["hidden_size"]?.try(&.as_i?) || return
      geometry = GEMMA3_TEXT_GEOMETRY[hidden_size]? || return

      patched = false
      geometry.each do |key, value|
        next if text_config.has_key?(key.to_s)
        text_config[key.to_s] = JSON::Any.new(value.to_i64)
        patched = true
      end
      return unless patched

      config["text_config"] = JSON::Any.new(text_config)
      File.write(config_path.to_s, JSON::Any.new(config).to_pretty_json)
    end

    # Lists repo files (with sizes) via the Hub API.
    private def list_model_files(repo_id : String, revision : String?) : Array(ModelFile)
      url = revision ? "#{@endpoint}/api/models/#{repo_id}/revision/#{revision}?blobs=true" \
                     : "#{@endpoint}/api/models/#{repo_id}?blobs=true"
      response = get_following_redirects(url)
      unless response.status.success?
        raise ModelUnavailableError.new(
          "Failed to list files for #{repo_id}#{revision ? "@#{revision}" : ""}: HTTP #{response.status_code} " \
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

    private def download_file(repo_id : String, revision : String?, file_name : String, destination : Path, &on_bytes : Int64 -> Nil) : Nil
      partial = Path["#{destination}.partial"]
      url = "#{@endpoint}/#{repo_id}/resolve/#{revision || "main"}/#{file_name}"

      get_following_redirects(url) do |response|
        unless response.status.success?
          raise ModelUnavailableError.new("Failed to download #{file_name} for #{repo_id}: HTTP #{response.status_code}")
        end

        File.open(partial.to_s, "w") do |file|
          if body = response.body_io?
            buffer = Bytes.new(256 * 1024)
            while (read = body.read(buffer)) > 0
              file.write(buffer[0, read])
              on_bytes.call(read.to_i64)
            end
          else
            # Non-streaming response (small files, or stubbed in specs).
            data = response.body
            file.write(data.to_slice)
            on_bytes.call(data.bytesize.to_i64)
          end
        end
      end

      FileUtils.mv(partial.to_s, destination.to_s)
    rescue ex : IO::Error | Socket::Error | OpenSSL::Error
      raise ModelUnavailableError.new(
        "Network error downloading #{file_name} for #{repo_id}: #{ex.message}. " \
        "Check your connection and retry - the download resumes from the file list, " \
        "already-completed files are kept."
      )
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
