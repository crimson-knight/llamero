# Binary entry point for the `crystal-training` subcommand prototype (Phase D).
# Kept outside src/native/** (which llamero.cr globs) so its top-level code is
# only compiled when building this target.
#
#   crystal build src/tools/crystal_training.cr -o bin/crystal-training
#   bin/crystal-training extract --markdown docs/ --out corpus.jsonl
require "../llamero"

exit Llamero::Native::CrystalTraining.run(ARGV)
