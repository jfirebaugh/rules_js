"""Runs a binary as a build action. This rule does not require Bash (unlike native.genrule()).

This fork of bazel-skylib's run_binary adds directory output support and better makevar expansions.
"""

load("@aspect_bazel_lib//lib:run_binary.bzl", _run_binary = "run_binary")
load("@aspect_bazel_lib//lib:copy_to_bin.bzl", _copy_to_bin = "copy_to_bin")
load("@bazel_skylib//lib:dicts.bzl", "dicts")

def run_js_binary(
        name,
        tool,
        env = {},
        srcs = [],
        output_dir = False,
        outs = [],
        args = [],
        chdir = None,
        stdout = None,
        stderr = None,
        exit_code_out = None,
        silent_on_success = True,
        copy_srcs_to_bin = True,
        **kwargs):
    """Wrapper around @aspect_bazel_lib run_binary that adds convienence attributes for using a js_binary tool.

    This rule does not require Bash `native.genrule`.

    Args:
        name: Target name
        tool: The tool to run in the action.

            Must be the label of a *_binary rule, of a rule that generates an executable file, or of a file
            that can be executed as a subprocess (e.g. an .exe or .bat file on Windows or a binary with
            executable permission on Linux). This label is available for `$(location)` expansion in `args` and
            `env`.

        env: Environment variables of the action.

            Subject to `$(location)` and make variable expansion.

        srcs: Additional inputs of the action.

            These labels are available for `$(location)` expansion in `args` and `env`.

        output_dir: Set to True if you want the output to be a directory.

            Exactly one of `outs`, `output_dir` may be used.
            If you output a directory, there can only be one output, which will be a
            directory named the same as the target.

        outs: Output files generated by the action.

            These labels are available for `$(location)` expansion in `args` and `env`.

        args: Command line arguments of the binary.

            Subject to `$(location)` and make variable expansion.

        chdir: Working directory to run the binary or test in, relative to the workspace.

            By default, Bazel always runs in the workspace root.

            To run in the directory containing the run_js_binary under the source tree, use
            `chdir = package_name()` (or if you're in a macro, use `native.package_name()`).

            To run in the output directory where the run_js_binary writes outputs, use
            `chdir = "$(RULEDIR)"`

            WARNING: this will affect other paths passed to the program, either as arguments or in configuration files,
            which are workspace-relative.

            You may need `../../` segments to re-relativize such paths to the new working directory.

        stderr: set to capture the stderr of the binary to a file, which can later be used as an input to another target
                subject to the same semantics as `outs`

        stdout: set to capture the stdout of the binary to a file, which can later be used as an input to another target
                subject to the same semantics as `outs`

        exit_code_out: set to capture the exit code of the binary to a file, which can later be used as an input to another target
                subject to the same semantics as `outs`. Note that setting this will force the binary to exit 0.
                If the binary creates outputs and these are declared, they must still be created

        silent_on_success: produce no output on stdout nor stderr when program exits with status code 0.
                This makes node binaries match the expected bazel paradigm.

        copy_srcs_to_bin: When True, all srcs files are copied to the output tree that are not already there.

        **kwargs: Additional arguments
    """
    extra_srcs = []
    if copy_srcs_to_bin:
        copy_to_bin_name = "%s_copy_srcs_to_bin" % name
        _copy_to_bin(
            name = copy_to_bin_name,
            srcs = srcs,
            tags = kwargs.get("tags"),
        )
        extra_srcs = [":%s" % copy_to_bin_name]

    # Automatically add common and useful make variables to the environment for js_binary targets
    # under rules_js
    extra_env = {
        "BAZEL_BINDIR": "$(BINDIR)",
        "BAZEL_BUILD_FILE_PATH": "$(BUILD_FILE_PATH)",
        "BAZEL_VERSION_FILE": "$(VERSION_FILE)",
        "BAZEL_INFO_FILE": "$(INFO_FILE)",
        "BAZEL_TARGET": "$(TARGET)",
        "BAZEL_WORKSPACE": "$(WORKSPACE)",
        "BAZEL_TARGET_CPU": "$(TARGET_CPU)",
        "BAZEL_COMPILATION_MODE": "$(COMPILATION_MODE)",
    }

    # Configure working directory to `chdir` is set
    chdir_prefix = ""
    if chdir:
        extra_env["JS_BINARY__CHDIR"] = chdir
        chdir_prefix = "/".join([".."] * len(chdir.split("/"))) + "/"

    # Configure capturing stdout, stderr and/or the exit code
    extra_outs = []
    if stdout:
        extra_env["JS_BINARY__CAPTURE_STDOUT"] = "%s$(rootpath %s)" % (chdir_prefix, stdout)
        extra_outs.append(stdout)
    if stderr:
        extra_env["JS_BINARY__CAPTURE_STDERR"] = "%s$(rootpath %s)" % (chdir_prefix, stderr)
        extra_outs.append(stderr)
    if exit_code_out:
        extra_env["JS_BINARY__CAPTURE_EXIT_CODE"] = "%s$(rootpath %s)" % (chdir_prefix, exit_code_out)
        extra_outs.append(exit_code_out)

    # Configure silent on success
    if silent_on_success:
        extra_env["JS_BINARY__SILENT_ON_SUCCESS"] = "1"

    _run_binary(
        name = name,
        tool = tool,
        env = dicts.add(extra_env, env),
        srcs = srcs + extra_srcs,
        output_dir = output_dir,
        outs = outs + extra_outs,
        args = args,
        **kwargs
    )
