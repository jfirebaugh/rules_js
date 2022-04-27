# e2e test for using rules_js from bzlmod

To avoid a `yq` dependency, the pnpm-lock file is translated to json using
`yq -o=json 'eval' pnpm-lock.yaml > pnpm-lock.json`
