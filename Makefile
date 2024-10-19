.PHONY: submodules

submodules:
	git submodule
		update \
		--init \
		--progress \
		--jobs 4
