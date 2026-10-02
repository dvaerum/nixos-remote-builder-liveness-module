# The one real value threaded into both refresh.sh (the caller, via
# config.nix) and dispatch.sh (the matcher, via userConfig.nix) -- a
# shared file instead of the same literal independently typed in two
# separate option-tree config files with nothing enforcing agreement
# between them.
"nix-dynamic-builders-query-features"
