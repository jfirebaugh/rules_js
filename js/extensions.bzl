"""Adapt repository rules in npm_import.bzl to be called from MODULE.bazel

See https://bazel.build/docs/bzlmod#extension-definition
"""

load("//js/private:translate_pnpm_lock.bzl", "npm_imports", "translate_pnpm_lock")
load("//js:npm_import.bzl", "npm_import")
load("//js/private:transitive_closure.bzl", "translate_to_transitive_closure")

def _extension_impl(module_ctx):
    for mod in module_ctx.modules:
        for lock in mod.tags.pnpm_lock:
            json_lockfile = json.decode(module_ctx.read(lock.pnpm_lock))
            trans = translate_to_transitive_closure(json_lockfile, lock.prod, lock.dev, lock.no_optional)
            imports = npm_imports(trans, lock.name, lock)
            for i in imports:
                # fixme: pass the rest of the kwargs from i
                npm_import(i.pop("name"), i.pop("package"), i.pop("pnpm_version"))

        #    translate_pnpm_lock(**{k: getattr(lock, k) for k in dir(lock)})

npm = module_extension(
    implementation = _extension_impl,
    tag_classes = {
        "pnpm_lock": tag_class(attrs = dict({"name": attr.string()}, **translate_pnpm_lock.attrs)),
        # todo: support individual packages as well
        # "package": tag_class(attrs = dict({"name": attr.string()}, **_npm_import.attrs)),
    },
)
