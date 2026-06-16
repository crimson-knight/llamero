require "../spec_helper"
require "file_utils"

private def with_adapter_dir(weights : Bool = true, &)
  dir = File.join(Dir.tempdir, "llamero-tf-src-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  if weights
    File.write(File.join(dir, "adapters.safetensors"), "fake-lora-weights")
    File.write(File.join(dir, "adapter_config.json"), %({"num_layers": 8, "lora_parameters": {"rank": 8, "scale": 1.0}}))
  end
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private def tmp_dir(&)
  dir = File.join(Dir.tempdir, "llamero-tf-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private def lora
  Llamero::Native::TrainingFilter::LoRASpec.new(rank: 8, scale: 1.0, num_layers: 8)
end

private def provenance
  Llamero::Native::TrainingFilter::Provenance.new(methods: ["unsupervised", "sft"])
end

private def pack_amber(src, dest, base_filter : String? = nil, metrics : Hash(String, Float64) = {} of String => Float64)
  Llamero::Native::TrainingFilter.pack(
    adapter_dir: src, dest: dest,
    name: "amber", version: "0.1.0",
    base_model: "mlx-community/gemma-3-1b-it-4bit",
    lora: lora, provenance: provenance,
    library: "amber", library_version: "2.0.0-dev",
    base_filter: base_filter, metrics: metrics,
  )
end

describe Llamero::Native::TrainingFilter do
  it "packs an adapter into a verifiable filter package" do
    with_adapter_dir do |src|
      tmp_dir do |root|
        dest = File.join(root, "amber.filter")
        filter = pack_amber(src, dest, metrics: {"compile" => 0.93, "format" => 0.97})

        filter.id.should eq("amber@0.1.0")
        filter.manifest.base_model.should eq("mlx-community/gemma-3-1b-it-4bit")
        filter.manifest.metrics["compile"].should eq(0.93)
        File.exists?(File.join(dest, "training_filter.json")).should be_true
        File.exists?(File.join(dest, "adapters.safetensors")).should be_true
        File.exists?(File.join(dest, "adapter_config.json")).should be_true
        Llamero::Native::TrainingFilter.package?(dest).should be_true
      end
    end
  end

  it "computes the same checksum a registry would for the packaged weights" do
    with_adapter_dir do |src|
      tmp_dir do |root|
        dest = File.join(root, "amber.filter")
        filter = pack_amber(src, dest)
        registry_checksum = Llamero::Native::AdapterRegistry.new.register("amber", dest).checksum
        filter.manifest.weights_checksum.should eq(registry_checksum)
      end
    end
  end

  it "round-trips through load and verifies integrity" do
    with_adapter_dir do |src|
      tmp_dir do |root|
        dest = File.join(root, "amber.filter")
        pack_amber(src, dest)

        loaded = Llamero::Native::TrainingFilter.load(dest)
        loaded.id.should eq("amber@0.1.0")
        loaded.library.should eq("amber")
        loaded.manifest.provenance.methods.should eq(["unsupervised", "sft"])
      end
    end
  end

  it "raises on a tampered package (checksum mismatch)" do
    with_adapter_dir do |src|
      tmp_dir do |root|
        dest = File.join(root, "amber.filter")
        pack_amber(src, dest)
        File.write(File.join(dest, "adapters.safetensors"), "tampered-weights!!")

        expect_raises(Llamero::Native::TrainingFilterError, /Checksum mismatch/) do
          Llamero::Native::TrainingFilter.load(dest)
        end
      end
    end
  end

  it "raises when the directory is not a filter package" do
    tmp_dir do |root|
      expect_raises(ArgumentError, /no training_filter.json/) do
        Llamero::Native::TrainingFilter.load(root)
      end
    end
  end

  describe "compatibility" do
    it "matches its base model and an optional fused base filter" do
      with_adapter_dir do |src|
        tmp_dir do |root|
          dest = File.join(root, "amber.filter")
          filter = pack_amber(src, dest, base_filter: "crystal@0.1.0")

          filter.compatible_with?("mlx-community/gemma-3-1b-it-4bit", "crystal@0.1.0").should be_true
          filter.compatible_with?("mlx-community/gemma-3-1b-it-4bit", nil).should be_false
          filter.compatible_with?("some/other-model", "crystal@0.1.0").should be_false
        end
      end
    end

    it "with no base_filter is compatible regardless of what is composed" do
      with_adapter_dir do |src|
        tmp_dir do |root|
          dest = File.join(root, "amber.filter")
          filter = pack_amber(src, dest)
          filter.compatible_with?("mlx-community/gemma-3-1b-it-4bit").should be_true
          filter.compatible_with?("mlx-community/gemma-3-1b-it-4bit", "anything").should be_true
        end
      end
    end
  end

  describe ".installed / .all discovery" do
    it "discovers compatible packages and skips incompatible ones" do
      with_adapter_dir do |src|
        tmp_dir do |filters_root|
          pack_amber(src, File.join(filters_root, "amber.filter"))
          # An incompatible filter targeting a different base.
          Llamero::Native::TrainingFilter.pack(
            adapter_dir: src, dest: File.join(filters_root, "other.filter"),
            name: "other", version: "1.0.0",
            base_model: "some/other-base", lora: lora, provenance: provenance)

          all = Llamero::Native::TrainingFilter.all(filters_root)
          all.map(&.id).sort.should eq(["amber@0.1.0", "other@1.0.0"])

          compatible = Llamero::Native::TrainingFilter.installed(
            base_model: "mlx-community/gemma-3-1b-it-4bit", dir: filters_root)
          compatible.map(&.id).should eq(["amber@0.1.0"])
        end
      end
    end

    it "returns empty for a missing filters directory" do
      Llamero::Native::TrainingFilter.all("/nonexistent/llamero/filters").should be_empty
    end
  end

  describe ".for_shard" do
    it "selects filters whose library is a project dependency" do
      with_adapter_dir do |src|
        tmp_dir do |root|
          filters_root = File.join(root, "filters")
          Dir.mkdir_p(filters_root)
          pack_amber(src, File.join(filters_root, "amber.filter"))
          Llamero::Native::TrainingFilter.pack(
            adapter_dir: src, dest: File.join(filters_root, "grant.filter"),
            name: "grant", version: "0.1.0",
            base_model: "mlx-community/gemma-3-1b-it-4bit",
            lora: lora, provenance: provenance, library: "grant")

          shard = File.join(root, "shard.yml")
          File.write(shard, <<-YAML)
          name: my_app
          version: 0.1.0
          dependencies:
            amber:
              github: amberframework/amber
            sqlite3:
              github: crystal-lang/crystal-sqlite3
          YAML

          matched = Llamero::Native::TrainingFilter.for_shard(
            shard, base_model: "mlx-community/gemma-3-1b-it-4bit", dir: filters_root)
          # amber is a dep (filter exists); grant is not a dep; sqlite3 has no filter.
          matched.map(&.id).should eq(["amber@0.1.0"])
        end
      end
    end

    it "parses dependency names from a shard.yml" do
      tmp_dir do |root|
        shard = File.join(root, "shard.yml")
        File.write(shard, <<-YAML)
        name: my_app
        dependencies:
          amber:
            github: amberframework/amber
          grant:
            github: amberframework/grant
        development_dependencies:
          ameba:
            github: crystal-ameba/ameba
        targets:
          my_app:
            main: src/my_app.cr
        YAML

        deps = Llamero::Native::TrainingFilter.shard_dependencies(shard)
        deps.sort.should eq(["amber", "ameba", "grant"])
      end
    end
  end
end
