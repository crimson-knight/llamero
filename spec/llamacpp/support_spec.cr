require "../spec_helper"

private def healthy_mock_runner : Llamero::LlamaCpp::MockRunner
  runner = Llamero::LlamaCpp::MockRunner.new
  runner.enqueue("version: 1 (#{Llamero::LlamaCpp.commit_fragment})\nbuilt with AppleClang for Darwin arm64")
  runner.enqueue(Llamero::LlamaCpp::SUPPORTED_BUILD[:required_flags].join("\n"))
  runner
end

describe Llamero::LlamaCpp do
  it "pins a concrete tag and commit that agree" do
    Llamero::LlamaCpp::PIN_TAG.should match(/^b\d+$/)
    Llamero::LlamaCpp::PIN_COMMIT.should match(/^[0-9a-f]{40}$/)
    Llamero::LlamaCpp::SUPPORTED_BUILD[:tag].should eq(Llamero::LlamaCpp::PIN_TAG)
  end

  it "resolves the pinned binary inside the storage root, never PATH" do
    Llamero.storage_root = Path[Dir.tempdir].join("llamero-spec-root")
    Llamero::LlamaCpp.pinned_binary_path.to_s.should eq(
      Path[Dir.tempdir].join("llamero-spec-root", "llamacpp", Llamero::LlamaCpp::PIN_TAG, "bin", "llama-completion").to_s
    )
  end

  describe Llamero::LlamaCpp::Probe do
    it "passes for a binary that reports the pinned commit and full flag surface" do
      probe = Llamero::LlamaCpp::Probe.new(healthy_mock_runner)
      probe.ok?.should be_true
      probe.failure_reason.should be_nil
    end

    it "fails closed when no binary exists at the pinned path, with the fix command" do
      runner = Llamero::LlamaCpp::MockRunner.new
      runner.everything_executable = false
      probe = Llamero::LlamaCpp::Probe.new(runner)

      probe.ok?.should be_false
      error = expect_raises(Llamero::LlamaCppUnavailableError) { probe.check! }
      error.message.not_nil!.should contain("requires pinned llama.cpp #{Llamero::LlamaCpp::PIN_TAG}")
      error.message.not_nil!.should contain("Detected: none")
      error.message.not_nil!.should contain("scripts/install_llamacpp.sh")
      error.message.not_nil!.should contain("--skip-postinstall")
    end

    it "rejects a binary with the wrong commit (a working PATH llama.cpp is still wrong)" do
      runner = Llamero::LlamaCpp::MockRunner.new
      runner.enqueue("version: 6099 (3899b39)\nbuilt with AppleClang for Darwin arm64")
      probe = Llamero::LlamaCpp::Probe.new(runner)

      reason = probe.failure_reason.not_nil!
      reason.should contain("Wrong llama.cpp build")
      reason.should contain("3899b39")
    end

    it "rejects a matching-version binary that lost a required flag" do
      runner = Llamero::LlamaCpp::MockRunner.new
      runner.enqueue("version: 1 (#{Llamero::LlamaCpp.commit_fragment})")
      runner.enqueue("--grammar\n--grammar-file\n--json-schema") # missing --json-schema-file
      probe = Llamero::LlamaCpp::Probe.new(runner)

      probe.failure_reason.not_nil!.should contain("missing required flags: --json-schema-file")
    end

    it "caches the probe result per process" do
      runner = healthy_mock_runner
      probe = Llamero::LlamaCpp::Probe.new(runner)
      probe.ok?.should be_true
      probe.ok?.should be_true
      runner.invocations.size.should eq(2) # --version + --help exactly once
    end
  end
end
