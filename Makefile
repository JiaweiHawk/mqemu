PWD						:= $(shell pwd)
NPROC					:= $(shell nproc)

.PHONY: env kernel submodules

env: kernel
	@echo -e '\033[0;32m[*]\033[0mbuild the mqemu environment'

kernel:
	sudo apt update && \
	sudo apt install -y \
		bc bear bison dwarves flex libelf-dev libssl-dev

	make \
		-C ${PWD}/kernel \
		defconfig

	${PWD}/kernel/scripts/config \
		--file ${PWD}/kernel/.config \
		-e CONFIG_DEBUG_INFO_DWARF5 && \
	yes "" | make \
		-C ${PWD}/kernel \
		oldconfig

	${PWD}/kernel/scripts/config \
		--file ${PWD}/kernel/.config \
		-e CONFIG_GDB_SCRIPTS && \
	yes "" | make \
		-C ${PWD}/kernel \
		oldconfig

	${PWD}/kernel/scripts/config \
		--file ${PWD}/kernel/.config \
		-e CONFIG_X86_X2APIC && \
	yes "" | make \
		-C ${PWD}/kernel \
		oldconfig

	${PWD}/kernel/scripts/config \
		--file ${PWD}/kernel/.config \
		-e CONFIG_KVM && \
	yes "" | make \
		-C ${PWD}/kernel \
		oldconfig

	${PWD}/kernel/scripts/config \
		--file ${PWD}/kernel/.config \
		-e CONFIG_$(shell lsmod | grep "^kvm_" | awk '{print $$1}') && \
	yes "" | make \
		-C ${PWD}/kernel \
		oldconfig

	bear \
		--append \
		--output ${PWD}/compile_commands.json \
		-- make \
			-C ${PWD}/kernel \
			-j ${NPROC}

	@echo -e '\033[0;32m[*]\033[0mbuild the linux kernel'

submodules:
	git submodule
		update \
		--init \
		--progress \
		--jobs 4
