require "../spec_helper"
require "file_utils"

private def with_docs(&)
  dir = File.join(Dir.tempdir, "llamero-ct-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "guide.md"), <<-MD)
  # Controllers

  A basic controller responds to an action:

  ```crystal
  class UsersController < ApplicationController
    def index
      "hi"
    end
  end
  ```

  ## Shell

  Install with:

  ```bash
  shards install
  ```
  MD
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private def run_ct(args : Array(String)) : {Int32, String, String}
  stdout_io = IO::Memory.new
  stderr_io = IO::Memory.new
  code = Llamero::Native::CrystalTraining.run(args, stdout_io, stderr_io)
  {code, stdout_io.to_s, stderr_io.to_s}
end

describe Llamero::Native::CrystalTraining do
  it "prints usage for help and bare invocation" do
    code, out, _ = run_ct(["help"])
    code.should eq(0)
    out.should contain("doc -> data -> adapter")

    code2, out2, _ = run_ct([] of String)
    code2.should eq(0)
    out2.should contain("USAGE")
  end

  it "errors on an unknown subcommand" do
    code, _, err = run_ct(["frobnicate"])
    code.should eq(1)
    err.should contain("unknown subcommand")
  end

  it "extracts Crystal pairs from markdown to stdout (dropping non-Crystal fences)" do
    with_docs do |dir|
      code, out, _ = run_ct(["extract", "--markdown", dir, "--kind", "pair"])
      code.should eq(0)
      lines = out.each_line.reject(&.strip.empty?).to_a
      lines.size.should eq(1) # the crystal block, not the bash block
      parsed = JSON.parse(lines.first)
      parsed["kind"].should eq("pair")
      parsed["completion"].as_s.should contain("class UsersController")
    end
  end

  it "keeps non-Crystal fences with --all-languages" do
    with_docs do |dir|
      _, out, _ = run_ct(["extract", "--markdown", dir, "--all-languages"])
      out.each_line.reject(&.strip.empty?).to_a.size.should eq(2)
    end
  end

  it "writes a kind-tagged corpus file with --out" do
    with_docs do |dir|
      out_path = File.join(dir, "corpus.jsonl")
      code, msg, _ = run_ct(["extract", "--markdown", dir, "--kind", "text", "--out", out_path])
      code.should eq(0)
      msg.should contain("-> #{out_path}")
      File.exists?(out_path).should be_true
      JSON.parse(File.read(out_path).each_line.reject(&.strip.empty?).first)["kind"].should eq("text")
    end
  end

  it "rejects an invalid --kind" do
    with_docs do |dir|
      code, _, err = run_ct(["extract", "--markdown", dir, "--kind", "bogus"])
      code.should eq(1)
      err.should contain("--kind must be pair or text")
    end
  end

  it "requires a source" do
    code, _, err = run_ct(["extract"])
    code.should eq(1)
    err.should contain("--shard DIR or --markdown PATH")
  end

  it "requires --model for the adapter subcommand" do
    with_docs do |dir|
      code, _, err = run_ct(["adapter", "--markdown", dir])
      code.should eq(1)
      err.should contain("--model is required")
    end
  end
end
