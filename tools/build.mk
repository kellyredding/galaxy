# Shared by every tool's Makefile: `include ../build.mk`.

# The linker takes each binary's minimum macOS from this. Unset, it is the
# building Mac's own version, and older Macs refuse to start the tool.
export MACOSX_DEPLOYMENT_TARGET = 15.0

# A release binary for Apple Silicon and Intel in one file. Crystal only
# compiles the Intel object and prints the link command, so that command is
# rerun with `-arch x86_64` added; Crystal's bundled static libraries hold both.
#
#   $(call universal_build,<binary name>,<entry file>)
define universal_build
	@mkdir -p $(BUILDDIR)
	crystal build --release --no-debug -o $(BUILDDIR)/$(1)-arm64 $(2)
	crystal build --release --no-debug --cross-compile \
	  --target x86_64-apple-macosx$(MACOSX_DEPLOYMENT_TARGET) \
	  -o $(BUILDDIR)/$(1)-x86_64 $(2) > $(BUILDDIR)/$(1)-link-x86_64.sh
	sh -c "$$(sed 's/^cc /cc -arch x86_64 /' $(BUILDDIR)/$(1)-link-x86_64.sh)"
	lipo -create -output $(BUILDDIR)/$(1) $(BUILDDIR)/$(1)-arm64 $(BUILDDIR)/$(1)-x86_64
endef
