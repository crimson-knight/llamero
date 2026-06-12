require "../spec_helper"

private def with_env(key : String, value : String?, &)
  previous = ENV[key]?
  if value
    ENV[key] = value
  else
    ENV.delete(key)
  end

  begin
    yield
  ensure
    if previous
      ENV[key] = previous
    else
      ENV.delete(key)
    end
    Llamero.reset_storage_root!
  end
end

private def temp_storage_root(name : String) : Path
  Path[Dir.tempdir].join("#{name}-#{Random::Secure.hex(6)}")
end

describe Llamero::Storage do
  it "defaults to the historical storage root" do
    with_env("LLAMERO_HOME", nil) do
      Llamero.storage_root.should eq(Path.home.join(".llamero"))
      Llamero::Native::ModelDownloader.new.cache_dir.should eq(Path.home.join(".llamero", "models"))
    end
  end

  it "uses LLAMERO_HOME when no programmatic root is set" do
    root = temp_storage_root("llamero-env-root")

    with_env("LLAMERO_HOME", root.to_s) do
      Llamero.storage_root.should eq(root.expand)
      Llamero::Storage.models_dir.should eq(root.join("models").expand)
      Llamero::Storage.adapters_dir.should eq(root.join("adapters").expand)
      Llamero::Storage.lib_dir.should eq(root.join("lib").expand)
      Llamero::Storage.audio_models_dir.should eq(root.join("audio_models").expand)
    end
  end

  it "lets programmatic configuration win over LLAMERO_HOME" do
    env_root = temp_storage_root("llamero-env-root")
    app_root = temp_storage_root("llamero-app-root")

    with_env("LLAMERO_HOME", env_root.to_s) do
      Llamero.storage_root = app_root

      Llamero.storage_root.should eq(app_root.expand)
      Llamero.storage_path("models", "org--model").should eq(app_root.join("models", "org--model").expand)
      Llamero::Native::ModelDownloader.new.cache_dir.should eq(app_root.join("models").expand)
    end
  end
end
