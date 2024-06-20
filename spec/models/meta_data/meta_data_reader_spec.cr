require "../../spec_helper"
MAGIC = "GGUF".to_slice

describe Llamero::MetaData::MetaDataReader do
  it "reads the meta data for llama3 and correctly finds the bos token id" do
    meta_data_reader = Llamero::MetaData::MetaDataReader.new(Path["~/models/meta-llama-3-8b-instruct-Q6_K.gguf"].expand(home: true))

    meta_data_reader.file_header[:magic].should eq(0x46554747)
    meta_data_reader.file_header[:version].should eq(0x00000003)
    meta_data_reader.bos_token.should eq("<|begin_of_text|>")
    meta_data_reader.eos_token.should eq("<|end_of_text|>")
  end

  it "reads the meta data for Mistral and correctly finds the bos token id" do
    meta_data_reader = Llamero::MetaData::MetaDataReader.new(Path["~/models/mistral-7b-instruct-v0.2.Q5_K_S.gguf"].expand(home: true))
    meta_data_reader.bos_token.should eq("<s>")
  end
end
