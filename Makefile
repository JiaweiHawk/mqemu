PWD						:= $(shell pwd)
NPROC					:= $(shell nproc)
ROOTFS_L1 				:= rootfs_l1

.PHONY: env kernel qemu rootfs_l1 submodules

env: kernel qemu rootfs_l1
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

qemu:
	sudo apt update && \
	sudo apt install -y \
		bear libfdt-dev libglib2.0-dev libpixman-1-dev ninja-build python3-pip zlib1g-dev

	cd ${PWD}/qemu && \
	./configure \
		--target-list=x86_64-softmmu \
		--enable-debug \
		--enable-kvm \
		--enable-virtfs

	bear \
		--append \
		--output ${PWD}/compile_commands.json \
		-- make \
			-C ${PWD}/qemu \
			-j ${NPROC}

	@echo -e '\033[0;32m[*]\033[0mbuild the qemu'

rootfs_l1:
	if [ ! -d ${PWD}/${ROOTFS_L1} ]; then \
		sudo apt update && \
		sudo apt install -y \
			debootstrap; \
		\
		sudo debootstrap \
			--components=main,contrib,non-free,non-free-firmware \
			stable \
			${PWD}/${ROOTFS_L1} \
			https://mirrors.tuna.tsinghua.edu.cn/debian/; \
		\
		sudo chroot \
			${PWD}/${ROOTFS_L1} \
			/bin/bash \
				-c "apt update && apt install -y gdb git make pciutils strace wget"; \
		\
		#设置主机名称 \
		echo "l1" | sudo tee ${PWD}/${ROOTFS_L1}/etc/hostname; \
		\
		#设置密码 \
		sudo chroot ${PWD}/${ROOTFS_L1} /bin/bash -c "passwd -d root"; \
	fi

	cd ${PWD}/${ROOTFS_L1} && \
	sudo find . | sudo cpio -o --format=newc -F ${PWD}/${ROOTFS_L1}.cpio >/dev/null

	@echo -e '\033[0;32m[*]\033[0mbuild the rootfs'

submodules:
	git submodule
		update \
		--init \
		--progress \
		--jobs 4
