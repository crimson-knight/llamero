require "../spec_helper"

describe Llamero::BaseEmbeddingModel do
  it "returns a standard embedding with #create_embedding_with" do
    base_model = Llamero::BaseEmbeddingModel.new(model_name: "ggml-sfr-embedding-mistral-q4_k_m.gguf")
    base_model.should be_a(Llamero::BaseEmbeddingModel)

    embedding = base_model.create_embedding_with("This is a test of the single embedding function")
    embedding.should be_a(Array(Float64))
    embedding.size.should eq(4096) # This is the number of vectors in the returned embedding for the sfr-embedding-mistral-q4_k_m model
  end

  it "returns a collection of embeddings" do
    base_model = Llamero::BaseEmbeddingModel.new(model_name: "ggml-sfr-embedding-mistral-q4_k_m.gguf", enable_logging: true)
    base_model.should be_a(Llamero::BaseEmbeddingModel)

    embeddings = base_model.create_embeddings_with(["test list item 1", "test list item 2"])
    embeddings.should be_a(Array(Array(Float64)))
    embeddings.size.should eq(2) # There should be two embeddings in the collection
    embeddings[0].size.should eq(4096) # Each embedding should have 4096 vectors
    embeddings[1].size.should eq(4096) # Each embedding should have 4096 vectors
  end
end
