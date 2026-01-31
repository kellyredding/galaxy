.PHONY: all clean statusline-build statusline-test statusline-check statusline-install statusline-clean

all: statusline-build

# Statusline tool
statusline-build:
	$(MAKE) -C tools/statusline build

statusline-dev:
	$(MAKE) -C tools/statusline dev

statusline-test:
	$(MAKE) -C tools/statusline test

statusline-check:
	$(MAKE) -C tools/statusline check

statusline-install:
	$(MAKE) -C tools/statusline install

statusline-clean:
	$(MAKE) -C tools/statusline clean

# Add more tools here as they're created
# handoff-build:
#	$(MAKE) -C tools/handoff build

clean: statusline-clean
