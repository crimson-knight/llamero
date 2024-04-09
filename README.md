# llamero

## Before you start

Currently, you will need to clone the llama.cpp repo, build it and symlink the bin to /usr/local/bin/llamacpp for this shard to work as intended.

You will also need python 3.12 or later.

```
brew install python3 pip
```

Then you can clone and build llama.cpp

```bash
cd ~/ && git clone git@github.com:ggerganov/llama.cpp.git && cd llama.cpp && make
```

Now create the symlink for the main binary, run this from within the llama.cpp directory root

For Mac users, this command will create a symlink for you
```bash
sudo ln -s /Users/${whoami}/llama.cpp/main /usr/local/bin/llamacpp
```

For linux:
```bash
sudo ln -s /home/${whoami}/llama.cpp/main /usr/local/bin/llamacpp
```

You will also need to download some models. This is a quick reference list. You can choose any model that's already quantized into gguf, or you can convert your own models using the llama.cpp quantization tool.

Choose a model from below to start with. The links should bring you directly to the model files page. You want to "download" the model file. 

| Model Name          | Description                                   | RAM Required | Prompt Template |
|---------------------|-----------------------------------------------| ------------ | --------------- |
| [Mixtral dolphin-2.7-mixtral-8x7b-GGUF](https://huggingface.co/TheBloke/dolphin-2.7-mixtral-8x7b-GGUF/blob/main/dolphin-2.7-mixtral-8x7b.Q4_K_M.gguf) | A quantized model optimized for 8x7b settings, works about as well as ChatGPT 4 | ~27GB        | [chat template](https://huggingface.co/TheBloke/dolphin-2.7-mixtral-8x7b-GGUF#prompt-template-chatml) |
| [Mistril-7B-instruct-v0.2-GGUF](https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/blob/main/mistral-7b-instruct-v0.2.Q5_K_S.gguf) | A quantized model from Mistril, works about as well as ChatGPT 3.5 | ~6GB | [chat template](https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF#prompt-template-mistral) |

You can always download a different model, it just needs to be in the `GGUF` format, or you'll need to quantize the model from llama.cpp's quantization tool.

Move the model you downloaded into a directory that you'll configure in your project to use.
I recommend `~/models`


## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     llamero:
       github: crimson-knight/llamero
   ```

2. Run `shards install`

## Usage

```crystal
require "llamero"
```

TODO: Write usage instructions here

## Development

 To Do:
 [] Generate chat templates by reading from the model (integrate with HF's C-lib)

TODO: Write development instructions here

## Contributing

1. Fork it (<https://github.com/crimson-knight/llamero/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [crimson-knight](https://github.com/crimson-knight) - creator and maintainer
