.PHONY: all clean statusline-build statusline-test statusline-check statusline-install statusline-clean ledger-build ledger-test ledger-check ledger-install ledger-clean

all: statusline-build ledger-build

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

# Ledger tool
ledger-build:
	$(MAKE) -C tools/ledger build

ledger-dev:
	$(MAKE) -C tools/ledger dev

ledger-test:
	$(MAKE) -C tools/ledger test

ledger-check:
	$(MAKE) -C tools/ledger check

ledger-install:
	$(MAKE) -C tools/ledger install

ledger-clean:
	$(MAKE) -C tools/ledger clean

clean: statusline-clean ledger-clean
