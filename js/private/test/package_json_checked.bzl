"@generated by @aspect_rules_js//js/private:npm_import.bzl for npm package rollup@2.70.2"

load("@aspect_bazel_lib//lib:directory_path.bzl", _directory_path = "directory_path")
load("@aspect_rules_js//js:defs.bzl", _js_binary = "js_binary", _js_test = "js_test")
load("@aspect_rules_js//js:run_js_binary.bzl", _run_js_binary = "run_js_binary")

def rollup(name, **kwargs):
    _directory_path(
        name = "%s__entry_point" % name,
        directory = ":jsp__rollup__2.70.2__dir",
        path = "dist/bin/rollup",
    )
    _js_binary(
        name = "%s__js_binary" % name,
        entry_point = ":%s__entry_point" % name,
    )
    _run_js_binary(
        name = name,
        tool = ":%s__js_binary" % name,
        **kwargs
    )

def rollup_test(name, **kwargs):
    _directory_path(
        name = "%s__entry_point" % name,
        directory = ":jsp__rollup__2.70.2__dir",
        path = "dist/bin/rollup",
    )
    _js_test(
        name = name,
        entry_point = ":%s__entry_point" % name,
        **kwargs
    )

def rollup_binary(name, **kwargs):
    _directory_path(
        name = "%s__entry_point" % name,
        directory = ":jsp__rollup__2.70.2__dir",
        path = "dist/bin/rollup",
    )
    _js_binary(
        name = name,
        entry_point = ":%s__entry_point" % name,
        **kwargs
    )

bin = struct(rollup = rollup, rollup_test = rollup_test, rollup_binary = rollup_binary)
