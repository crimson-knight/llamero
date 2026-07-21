require "../spec_helper"

private def siblings_json(files : Array({String, Int64}))
  {
    "siblings" => files.map { |(name, size)| {"rfilename" => name, "size" => size} },
  }.to_json
end

private def with_tmp_cache(&)
  dir = File.tempname("llamero-dl-spec")
  Dir.mkdir_p(dir)
  yield Path[dir]
ensure
  FileUtils.rm_rf(dir.not_nil!) if dir
end

describe Llamero::Native::ModelDownloader do
  describe ".split_revision" do
    it "returns the id and nil when no revision is pinned" do
      Llamero::Native::ModelDownloader.split_revision("org/model").should eq({"org/model", nil})
    end

    it "splits a pinned revision" do
      Llamero::Native::ModelDownloader.split_revision("org/model@abc123")
        .should eq({"org/model", "abc123"})
    end
  end

  describe "#model_dir" do
    it "caches pinned revisions separately from the default branch" do
      with_tmp_cache do |cache|
        downloader = Llamero::Native::ModelDownloader.new(cache_dir: cache)
        plain = downloader.model_dir("org/model")
        pinned = downloader.model_dir("org/model@abc123")
        plain.should_not eq(pinned)
        pinned.basename.should eq("org--model@abc123")
      end
    end
  end

  describe "#resolve" do
    it "raises ModelUnavailableError with a typo hint on 404" do
      WebMock.stub(:get, "https://huggingface.co/api/models/org/nope?blobs=true")
        .to_return(status: 404, body: "Not Found")
      with_tmp_cache do |cache|
        downloader = Llamero::Native::ModelDownloader.new(cache_dir: cache)
        expect_raises(Llamero::Native::ModelUnavailableError, /HTTP 404/) do
          downloader.resolve("org/nope")
        end
      end
    end

    it "hints at HF_TOKEN for gated models on 401" do
      WebMock.stub(:get, "https://huggingface.co/api/models/org/gated?blobs=true")
        .to_return(status: 401, body: "Unauthorized")
      with_tmp_cache do |cache|
        downloader = Llamero::Native::ModelDownloader.new(cache_dir: cache)
        expect_raises(Llamero::Native::ModelUnavailableError, /gated model\? set HF_TOKEN/) do
          downloader.resolve("org/gated")
        end
      end
    end

    it "rejects repos without safetensors weights with an actionable message" do
      WebMock.stub(:get, "https://huggingface.co/api/models/org/gguf-only?blobs=true")
        .to_return(status: 200, body: siblings_json([
          {"config.json", 100_i64},
          {"model.gguf", 1000_i64},
        ]))
      with_tmp_cache do |cache|
        downloader = Llamero::Native::ModelDownloader.new(cache_dir: cache)
        expect_raises(Llamero::Native::ModelUnavailableError, /no \.safetensors weights.*mlx-community/m) do
          downloader.resolve("org/gguf-only")
        end
      end
    end

    it "lists and downloads from the pinned revision URLs" do
      WebMock.stub(:get, "https://huggingface.co/api/models/org/model/revision/abc123?blobs=true")
        .to_return(status: 200, body: siblings_json([
          {"config.json", 2_i64},
          {"model.safetensors", 2_i64},
        ]))
      WebMock.stub(:get, "https://huggingface.co/org/model/resolve/abc123/config.json")
        .to_return(status: 200, body: "{}")
      WebMock.stub(:get, "https://huggingface.co/org/model/resolve/abc123/model.safetensors")
        .to_return(status: 200, body: "xx")

      with_tmp_cache do |cache|
        downloader = Llamero::Native::ModelDownloader.new(cache_dir: cache)
        dir = downloader.resolve("org/model@abc123")
        File.exists?(dir.join("config.json").to_s).should be_true
        File.exists?(dir.join("model.safetensors").to_s).should be_true
        downloader.cached?("org/model@abc123").should be_true
        downloader.cached?("org/model").should be_false
      end
    end

    it "completes incomplete multimodal gemma3 text_config at download time" do
      config = {
        "model_type"  => "gemma3",
        "text_config" => {"hidden_size" => 2560, "num_hidden_layers" => 34},
      }.to_json
      WebMock.stub(:get, "https://huggingface.co/api/models/org/g3?blobs=true")
        .to_return(status: 200, body: siblings_json([
          {"config.json", config.bytesize.to_i64},
          {"model.safetensors", 2_i64},
        ]))
      WebMock.stub(:get, "https://huggingface.co/org/g3/resolve/main/config.json")
        .to_return(status: 200, body: config)
      WebMock.stub(:get, "https://huggingface.co/org/g3/resolve/main/model.safetensors")
        .to_return(status: 200, body: "xx")

      with_tmp_cache do |cache|
        downloader = Llamero::Native::ModelDownloader.new(cache_dir: cache)
        dir = downloader.resolve("org/g3")
        patched = JSON.parse(File.read(dir.join("config.json").to_s))
        patched["text_config"]["num_attention_heads"].as_i.should eq(8)
        patched["text_config"]["num_key_value_heads"].as_i.should eq(4)
        patched["text_config"]["head_dim"].as_i.should eq(256)
        patched["text_config"]["num_hidden_layers"].as_i.should eq(34)
      end
    end

    it "leaves complete or non-gemma3 configs untouched" do
      config = {"model_type" => "llama", "hidden_size" => 4096}.to_json
      WebMock.stub(:get, "https://huggingface.co/api/models/org/plain?blobs=true")
        .to_return(status: 200, body: siblings_json([
          {"config.json", config.bytesize.to_i64},
          {"model.safetensors", 2_i64},
        ]))
      WebMock.stub(:get, "https://huggingface.co/org/plain/resolve/main/config.json")
        .to_return(status: 200, body: config)
      WebMock.stub(:get, "https://huggingface.co/org/plain/resolve/main/model.safetensors")
        .to_return(status: 200, body: "xx")

      with_tmp_cache do |cache|
        downloader = Llamero::Native::ModelDownloader.new(cache_dir: cache)
        dir = downloader.resolve("org/plain")
        JSON.parse(File.read(dir.join("config.json").to_s)).should eq(JSON.parse(config))
      end
    end
  end
end
