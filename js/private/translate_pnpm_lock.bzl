"Convert pnpm lock file into starlark Bazel fetches"

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//lib:dicts.bzl", "dicts")
load(":pnpm_utils.bzl", "pnpm_utils")
load(":transitive_closure.bzl", "translate_to_transitive_closure")
load(":starlark_codegen_utils.bzl", "starlark_codegen_utils")

_DOC = """Repository rule to generate npm_import rules from pnpm lock file.

The pnpm lockfile format includes all the information needed to define npm_import rules,
including the integrity hash, as calculated by the package manager.

For more details see, https://github.com/pnpm/pnpm/blob/main/packages/lockfile-types/src/index.ts.

Instead of manually declaring the `npm_imports`, this helper generates an external repository
containing a helper starlark module `repositories.bzl`, which supplies a loadable macro
`npm_repositories`. This macro creates an `npm_import` for each package.

The generated repository also contains BUILD files declaring targets for the packages
listed as `dependencies` or `devDependencies` in `package.json`, so you can declare
dependencies on those packages without having to repeat version information.

Bazel will only fetch the packages which are required for the requested targets to be analyzed.
Thus it is performant to convert a very large pnpm-lock.yaml file without concern for
users needing to fetch many unnecessary packages.

**Setup**

In `WORKSPACE`, call the repository rule pointing to your pnpm-lock.yaml file:

```starlark
load("@aspect_rules_js//js:npm_import.bzl", "translate_pnpm_lock")

# Read the pnpm-lock.yaml file to automate creation of remaining npm_import rules
translate_pnpm_lock(
    # Creates a new repository named "@npm_deps"
    name = "npm_deps",
    pnpm_lock = "//:pnpm-lock.yaml",
)
```

Next, there are two choices, either load from the generated repo or check in the generated file.
The tradeoffs are similar to
[this rules_python thread](https://github.com/bazelbuild/rules_python/issues/608).

1. Immediately load from the generated `repositories.bzl` file in `WORKSPACE`.
This is similar to the 
[`pip_parse`](https://github.com/bazelbuild/rules_python/blob/main/docs/pip.md#pip_parse)
rule in rules_python for example.
It has the advantage of also creating aliases for simpler dependencies that don't require
spelling out the version of the packages.
However it causes Bazel to eagerly evaluate the `translate_pnpm_lock` rule for every build,
even if the user didn't ask for anything JavaScript-related.

```starlark
load("@npm_deps//:repositories.bzl", "npm_repositories")

npm_repositories()
```

In BUILD files, declare dependencies on the packages using the same external repository.

Following the same example, this might look like:

```starlark
js_test(
    name = "test_test",
    data = ["@npm_deps//@types/node"],
    entry_point = "test.js",
)
```

2. Check in the `repositories.bzl` file to version control, and load that instead.
This makes it easier to ship a ruleset that has its own npm dependencies, as users don't
have to install those dependencies. It also avoids eager-evaluation of `translate_pnpm_lock`
for builds that don't need it.
This is similar to the [`update-repos`](https://github.com/bazelbuild/bazel-gazelle#update-repos)
approach from bazel-gazelle.

In a BUILD file, use a rule like
[write_source_files](https://github.com/aspect-build/bazel-lib/blob/main/docs/write_source_files.md)
to copy the generated file to the repo and test that it stays updated:

```starlark
write_source_files(
    name = "update_repos",
    files = {
        "repositories.bzl": "@npm_deps//:repositories.bzl",
    },
)
```

Then in `WORKSPACE`, load from that checked-in copy or instruct your users to do so.
In this case, the aliases are not created, so you get only the `npm_import` behavior
and must depend on packages with their versioned label like `@npm__types_node-15.12.2`.
"""

_ATTRS = {
    "pnpm_lock": attr.label(
        doc = """The pnpm-lock.yaml file.""",
        mandatory = True,
    ),
    "patches": attr.string_list_dict(
        doc = """A map of package names or package names with their version (e.g., "my-package" or "my-package@v1.2.3")
        to a label list of patches to apply to the downloaded npm package. Paths in the patch
        file must start with `extract_tmp/package` where `package` is the top-level folder in
        the archive on npm. If the version is left out of the package name, the patch will be
        applied to every version of the npm package.""",
    ),
    "patch_args": attr.string_list_dict(
        doc = """A map of package names or package names with their version (e.g., "my-package" or "my-package@v1.2.3")
        to a label list arguments to pass to the patch tool. Defaults to -p0, but -p1 will
        usually be needed for patches generated by git. If patch args exists for a package
        as well as a package version, then the version-specific args will be appended to the args for the package.""",
    ),
    "custom_postinstalls": attr.string_dict(
        doc = """A map of package names or package names with their version (e.g., "my-package" or "my-package@v1.2.3")
        to a custom postinstall script to apply to the downloaded npm package after its lifecycle scripts runs.
        If the version is left out of the package name, the script will run on every version of the npm package. If
        a custom postinstall scripts exists for a package as well as for a specific version, the script for the versioned package
        will be appended with `&&` to the non-versioned package script.""",
    ),
    "prod": attr.bool(
        doc = """If true, only install dependencies""",
    ),
    "dev": attr.bool(
        doc = """If true, only install devDependencies""",
    ),
    "no_optional": attr.bool(
        doc = """If true, optionalDependencies are not installed""",
    ),
    "lifecycle_hooks_exclude": attr.string_list(
        doc = """A list of package names or package names with their version (e.g., "my-package" or "my-package@v1.2.3")
        to not run lifecycle hooks on""",
    ),
    "run_lifecycle_hooks": attr.bool(
        doc = """If true, runs preinstall, install and postinstall lifecycle hooks on npm packages if they exist""",
        default = True,
    ),
}

def _process_lockfile(rctx):
    lockfile = pnpm_utils.parse_pnpm_lock(rctx.read(rctx.path(rctx.attr.pnpm_lock)))
    return translate_to_transitive_closure(lockfile, rctx.attr.prod, rctx.attr.dev, rctx.attr.no_optional)

_NPM_IMPORT_TMPL = \
    """    npm_import(
        name = "{name}",
        integrity = "{integrity}",
        root_path = "{root_path}",
        link_paths = {link_paths},
        package = "{package}",
        version = "{pnpm_version}",{maybe_deps}{maybe_transitive_closure}{maybe_patches}{maybe_patch_args}{maybe_run_lifecycle_hooks}{maybe_custom_postinstall}
    )
"""

_ALIAS_TMPL = \
    """load("//:defs.bzl", _package = "package", _package_dir = "package_dir")

alias(
    name = "{basename}",
    actual = _package("{name}", "{import_path}"),
    visibility = ["//visibility:public"],
)

alias(
    name = "dir",
    actual = _package_dir("{name}", "{import_path}"),
    visibility = ["//visibility:public"],
)"""

_PACKAGE_TMPL = \
    """
def package(name, import_path = "."):
    package_path = _paths.normalize(_paths.join("{root_path}", import_path))
    if package_path == ".":
        package_path = ""
    return Label("@{workspace}//{{package_path}}:{namespace}{{bazel_name}}".format(
        package_path = package_path,
        bazel_name = _pnpm_utils.bazel_name(name),
    ))

def package_dir(name, import_path = "."):
    package_path = _paths.normalize(_paths.join("{root_path}", import_path))
    if package_path == ".":
        package_path = ""
    return Label("@{workspace}//{{package_path}}:{namespace}{{bazel_name}}{dir_postfix}".format(
        package_path = package_path,
        bazel_name = _pnpm_utils.bazel_name(name),
    ))
"""

_BIN_TMPL = \
    """load("@{repo_name}//:package_json.bzl", _bin = "bin")
bin = _bin
"""

_FP_STORE_TMPL = \
    """
    if is_root:
         _link_js_package_store(
            name = "{namespace}{bazel_name}{store_postfix}",
            src = "{js_package_target}",
            package = "{package}",
            version = "0.0.0",
            deps = {deps},
            visibility = ["//visibility:public"],
        )"""

_FP_DIRECT_TMPL = \
    """
    for link_path in {link_paths}:
        link_package_path = _paths.normalize(_paths.join("{root_path}", link_path))
        if link_package_path == ".":
            link_package_path = ""
        if link_package_path == native.package_name():
            # terminal target for direct dependencies
            _link_js_package_direct(
                name = "{namespace}{bazel_name}",
                src = "//{root_path}:{namespace}{bazel_name}{store_postfix}",
                visibility = ["//visibility:public"],
            )

            # filegroup target that provides a single file which is
            # package directory for use in $(execpath) and $(rootpath)
            native.filegroup(
                name = "{namespace}{bazel_name}{dir_postfix}",
                srcs = [":{namespace}{bazel_name}"],
                output_group = "{package_directory_output_group}",
                visibility = ["//visibility:public"],
            )

            native.alias(
                name = "{namespace}{alias}",
                actual = ":{namespace}{bazel_name}",
                visibility = ["//visibility:public"],
            )

            native.alias(
                name = "{namespace}{alias}{dir_postfix}",
                actual = ":{namespace}{bazel_name}{dir_postfix}",
                visibility = ["//visibility:public"],
            )"""

def _generated_by_lines(pnpm_lock_wksp, pnpm_lock):
    return [
        "\"@generated by @aspect_rules_js//js/private:translate_pnpm_lock.bzl from pnpm lock file @{pnpm_lock_wksp}{pnpm_lock}\"".format(
            pnpm_lock_wksp = pnpm_lock_wksp,
            pnpm_lock = str(pnpm_lock),
        ),
        "",  # empty line after bzl docstring since buildifier expects this if this file is vendored in
    ]

def _fp_link_path(root_path, import_path, rel_path):
    fp_link_path = paths.normalize(paths.join(root_path, import_path, rel_path))
    if fp_link_path == ".":
        fail("root bazel package first party dep not supported")
    return fp_link_path

def _impl(rctx):
    if rctx.attr.prod and rctx.attr.dev:
        fail("prod and dev attributes cannot both be set to true")

    lockfile = _process_lockfile(rctx)

    # root path is the directory of the pnpm_lock file
    root_path = rctx.attr.pnpm_lock.package

    # don't allow a pnpm lock file that isn't in the root directory of a bazel package
    if paths.dirname(rctx.attr.pnpm_lock.name):
        fail("pnpm-lock.yaml file must be at the root of a bazel package")

    importers = lockfile.get("importers")
    if not importers:
        fail("expected importers in processed lockfile")

    packages = lockfile.get("packages")
    if not packages:
        fail("expected packages in processed lockfile")

    generated_by_lines = _generated_by_lines(rctx.attr.pnpm_lock.workspace_name, rctx.attr.pnpm_lock)

    repositories_bzl = generated_by_lines + [
        """load("@aspect_rules_js//js:npm_import.bzl", "npm_import")""",
        "",
        "def npm_repositories():",
        "    \"Generated npm_import repository rules corresponding to npm packages in @{pnpm_lock_wksp}{pnpm_lock}\"".format(
            pnpm_lock_wksp = str(rctx.attr.pnpm_lock.workspace_name),
            pnpm_lock = str(rctx.attr.pnpm_lock),
        ),
    ]

    importer_paths = importers.keys()

    defs_bzl_file = "defs.bzl"
    defs_bzl_header = generated_by_lines + [
        """load("@aspect_rules_js//js/private:pnpm_utils.bzl", _pnpm_utils = "pnpm_utils")""",
        """load("@bazel_skylib//lib:paths.bzl", _paths = "paths")""",
    ]
    defs_bzl_body = [
        """# buildifier: disable=unnamed-macro
def link_js_packages():
    "Generated list of link_js_package() target generators and first party linked packages corresponding to the packages in @{pnpm_lock_wksp}{pnpm_lock}"
    root_path = "{root_path}"
    importer_paths = {importer_paths}
    is_root = native.package_name() == root_path
    is_direct = False
    for import_path in importer_paths:
        importer_package_path = _paths.normalize(_paths.join(root_path, import_path))
        if importer_package_path == ".":
            importer_package_path = ""
        if importer_package_path == native.package_name():
            is_direct = True
    if not is_root and not is_direct:
        msg = "The link_js_packages() macro loaded from {defs_bzl_file} and called in bazel package '%s' may only be called in the bazel package(s) corresponding to the root package '{root_path}' and packages corresponding to importer paths [{importer_paths_comma_separated}]" % native.package_name()
        fail(msg)
""".format(
            pnpm_lock_wksp = str(rctx.attr.pnpm_lock.workspace_name),
            pnpm_lock = str(rctx.attr.pnpm_lock),
            root_path = root_path,
            importer_paths = str(importer_paths),
            importer_paths_comma_separated = "'" + "', '".join(importer_paths) + "'" if len(importer_paths) else "",
            defs_bzl_file = "@{}//:{}".format(rctx.name, defs_bzl_file),
        ),
    ]

    for (i, v) in enumerate(packages.items()):
        (package, package_info) = v
        name = package_info.get("name")
        pnpm_version = package_info.get("pnpmVersion")
        deps = package_info.get("dependencies")
        optional_deps = package_info.get("optionalDependencies")
        dev = package_info.get("dev")
        optional = package_info.get("optional")
        has_bin = package_info.get("hasBin")
        requires_build = package_info.get("requiresBuild")
        integrity = package_info.get("integrity")
        transitive_closure = package_info.get("transitiveClosure")

        if rctx.attr.prod and dev:
            # when prod attribute is set, skip devDependencies
            continue
        if rctx.attr.dev and not dev:
            # when dev attribute is set, skip (non-dev) dependencies
            continue
        if rctx.attr.no_optional and optional:
            # when no_optional attribute is set, skip optionalDependencies
            continue

        if not rctx.attr.no_optional:
            deps = dicts.add(optional_deps, deps)

        friendly_name = pnpm_utils.friendly_name(name, pnpm_utils.strip_peer_dep_version(pnpm_version))

        patches = rctx.attr.patches.get(name, [])[:]
        patches.extend(rctx.attr.patches.get(friendly_name, []))

        patch_args = rctx.attr.patch_args.get(name, [])[:]
        patch_args.extend(rctx.attr.patch_args.get(friendly_name, []))

        custom_postinstall = rctx.attr.custom_postinstalls.get(name)
        if not custom_postinstall:
            custom_postinstall = rctx.attr.custom_postinstalls.get(friendly_name)
        elif rctx.attr.custom_postinstalls.get(friendly_name):
            custom_postinstall = "%s && %s" % (custom_postinstall, rctx.attr.custom_postinstalls.get(friendly_name))

        repo_name = "%s__%s" % (rctx.name, pnpm_utils.bazel_name(name, pnpm_version))

        link_paths = []

        for import_path, importer in importers.items():
            dependencies = importer.get("dependencies")
            if type(dependencies) != "dict":
                fail("expected dict of dependencies in processed importer '%s'" % import_path)
            for dep_package, dep_version in dependencies.items():
                if not dep_version.startswith("link:") and package == pnpm_utils.pnpm_name(dep_package, dep_version):
                    # this package is a direct dependency at this import path
                    link_paths.append(import_path)

        run_lifecycle_hooks = requires_build and rctx.attr.run_lifecycle_hooks and name not in rctx.attr.lifecycle_hooks_exclude and friendly_name not in rctx.attr.lifecycle_hooks_exclude

        maybe_deps = ("""
        deps = %s,""" % starlark_codegen_utils.to_dict_attr(deps, 2)) if len(deps) > 0 else ""
        maybe_transitive_closure = ("""
        transitive_closure = %s,""" % starlark_codegen_utils.to_dict_list_attr(transitive_closure, 2)) if len(transitive_closure) > 0 else ""
        maybe_patches = ("""
        patches = %s,""" % patches) if len(patches) > 0 else ""
        maybe_patch_args = ("""
        patch_args = %s,""" % patch_args) if len(patches) > 0 and len(patch_args) > 0 else ""
        maybe_custom_postinstall = ("""
        custom_postinstall = \"%s\",""" % custom_postinstall) if custom_postinstall else ""
        maybe_run_lifecycle_hooks = ("""
        run_lifecycle_hooks = True,""") if run_lifecycle_hooks else ""

        repositories_bzl.append(_NPM_IMPORT_TMPL.format(
            integrity = integrity,
            link_paths = link_paths,
            maybe_custom_postinstall = maybe_custom_postinstall,
            maybe_deps = maybe_deps,
            maybe_patch_args = maybe_patch_args,
            maybe_patches = maybe_patches,
            maybe_run_lifecycle_hooks = maybe_run_lifecycle_hooks,
            maybe_transitive_closure = maybe_transitive_closure,
            name = repo_name,
            package = name,
            pnpm_version = pnpm_version,
            root_path = root_path,
        ))

        defs_bzl_header.append(
            """load("@{repo_name}{links_postfix}//:link_js_package.bzl", link_{i} = "link_js_package")""".format(
                i = i,
                repo_name = repo_name,
                links_postfix = pnpm_utils.links_postfix,
            ),
        )
        defs_bzl_body.append("    link_{i}(False)".format(i = i))

        if len(link_paths) and has_bin:
            # Generate a package_json.bzl file if there are bin entries
            rctx.file("%s/package_json.bzl" % name, "\n".join([
                _BIN_TMPL.format(
                    name = name,
                    repo_name = repo_name,
                ),
            ]))

        # For direct dependencies create alias targets @repo_name//name, @repo_name//@scope/name,
        # @repo_name//name:dir and @repo_name//@scope/name:dir
        for link_path in link_paths:
            escaped_link_path = link_path.replace("../", "dot_dot/")
            build_file_path = paths.normalize(paths.join(escaped_link_path, name, "BUILD.bazel"))
            rctx.file(build_file_path, "\n".join(generated_by_lines + [
                _ALIAS_TMPL.format(
                    basename = paths.basename(name),
                    import_path = link_path,
                    name = name,
                ),
            ]))

    fp_links = {}

    for import_path, importer in importers.items():
        dependencies = importer.get("dependencies")
        if type(dependencies) != "dict":
            fail("expected dict of dependencies in processed importer '%s'" % import_path)
        for dep_package, dep_version in dependencies.items():
            if dep_version.startswith("link:"):
                dep_importer = _fp_link_path(".", import_path, dep_version[len("link:"):])
                dep_path = _fp_link_path(root_path, import_path, dep_version[len("link:"):])
                dep_key = "{}+{}".format(dep_package, dep_path)
                if dep_key in fp_links.keys():
                    fp_links[dep_key]["link_paths"].append(import_path)
                else:
                    transitive_deps = []
                    raw_deps = {}
                    if dep_importer in importers.keys():
                        raw_deps = importers.get(dep_importer).get("dependencies")
                    for raw_package, raw_version in raw_deps.items():
                        if raw_version.startswith("link:"):
                            raw_path = _fp_link_path(root_path, dep_importer, raw_version[len("link:"):])
                            raw_bazel_name = pnpm_utils.bazel_name(raw_package, raw_path)
                        else:
                            raw_bazel_name = pnpm_utils.bazel_name(raw_package, raw_version)
                        transitive_deps.append("//{root_path}:{namespace}{bazel_name}{store_postfix}".format(
                            root_path = root_path,
                            namespace = pnpm_utils.js_package_target_namespace,
                            bazel_name = raw_bazel_name,
                            store_postfix = pnpm_utils.store_postfix,
                        ))
                    fp_links[dep_key] = {
                        "package": dep_package,
                        "path": dep_path,
                        "link_paths": [import_path],
                        "deps": transitive_deps,
                    }

    if fp_links:
        defs_bzl_header.append("""load("@aspect_rules_js//js/private:link_js_package.bzl",
    _link_js_package_store = "link_js_package_store",
    _link_js_package_direct = "link_js_package_direct")""")

    for fp_link in fp_links.values():
        fp_package = fp_link.get("package")
        fp_path = fp_link.get("path")
        fp_link_paths = fp_link.get("link_paths")
        fp_deps = fp_link.get("deps")
        fp_bazel_name = pnpm_utils.bazel_name(fp_package, fp_path)
        fp_target = "//{}:{}".format(fp_path, paths.basename(fp_path))

        defs_bzl_body.append(_FP_STORE_TMPL.format(
            bazel_name = fp_bazel_name,
            deps = starlark_codegen_utils.to_list_attr(fp_deps, 3),
            js_package_target = fp_target,
            namespace = pnpm_utils.js_package_target_namespace,
            package = fp_package,
            store_postfix = pnpm_utils.store_postfix,
        ))

        defs_bzl_body.append(_FP_DIRECT_TMPL.format(
            alias = pnpm_utils.bazel_name(fp_package),
            bazel_name = fp_bazel_name,
            dir_postfix = pnpm_utils.dir_postfix,
            link_paths = fp_link_paths,
            namespace = pnpm_utils.js_package_target_namespace,
            package = fp_package,
            package_directory_output_group = pnpm_utils.package_directory_output_group,
            root_path = root_path,
            store_postfix = pnpm_utils.store_postfix,
        ))

        # Create alias targets @repo_name//name, @repo_name//@scope/name,
        # @repo_name//name:dir and @repo_name//@scope/name:dir
        for link_path in fp_link_paths:
            escaped_link_path = link_path.replace("../", "dot_dot/")
            build_file_path = paths.normalize(paths.join(escaped_link_path, fp_package, "BUILD.bazel"))
            rctx.file(build_file_path, "\n".join(generated_by_lines + [
                _ALIAS_TMPL.format(
                    basename = paths.basename(fp_package),
                    import_path = link_path,
                    name = fp_package,
                ),
            ]))

    defs_bzl_body.append(_PACKAGE_TMPL.format(
        dir_postfix = pnpm_utils.dir_postfix,
        namespace = pnpm_utils.js_package_target_namespace,
        root_path = root_path,
        workspace = rctx.attr.pnpm_lock.workspace_name,
    ))

    rctx.file(defs_bzl_file, "\n".join(defs_bzl_header + [""] + defs_bzl_body))
    rctx.file("repositories.bzl", "\n".join(repositories_bzl))
    rctx.file("BUILD.bazel", """exports_files(["defs.bzl", "repositories.bzl"])""")

translate_pnpm_lock = struct(
    doc = _DOC,
    implementation = _impl,
    attrs = _ATTRS,
)

translate_pnpm_lock_testonly = struct(
    testonly_process_lockfile = _process_lockfile,
)
