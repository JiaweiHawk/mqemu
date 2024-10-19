PWD						:= $(shell pwd)
NPROC					:= $(shell nproc)
ROOTFS_L1 				:= rootfs_l1
TAP_L1 					:= tap1

define QEMU_OPTIONS_L0
	-cpu host \
	-smp 4 \
	-m 4G \
	-kernel ${PWD}/kernel/arch/x86_64/boot/bzImage \
	-append "rdinit=/sbin/init root=sr0 panic=-1 console=ttyS0 nokaslr" \
	-initrd ${PWD}/${ROOTFS_L1}.cpio \
	-netdev tap,id=net,ifname=${TAP_L1},script=no,downscript=no \
	-device virtio-net-pci,netdev=net \
	-enable-kvm \
	-no-reboot
endef #define QEMU_OPTIONS_L0

.PHONY: create_net_l1 delete_net_l1 env kernel qemu rootfs_l1 run_l1 submodules

env: kernel qemu rootfs_l1
	@echo -e '\033[0;32m[*]\033[0mbuild the mqemu environment'

create_net_l1:
	#开启ip转发
	sudo sysctl -w net.ipv4.ip_forward=1

	#创建tap
	sudo ip tuntap add name ${TAP_L1} mode tap

	#添加子网
	sudo ip addr add 172.192.168.1/24 dev ${TAP_L1}

	#启动dhcp服务
	sudo dnsmasq --interface=${TAP_L1} --bind-interfaces --dhcp-range=172.192.168.2,172.192.168.255 -x ${PWD}/dnsmasq_l1.pid

	#启动tap
	sudo ip link set dev ${TAP_L1} up

	#添加NAT规则
	sudo iptables -t nat -A POSTROUTING \
		-o $$(ip route | tail -n -1 | awk '{print $$3}') \
		-j MASQUERADE


delete_net_l1:
	#删除NAT规则
	sudo iptables -t nat -D POSTROUTING \
		-o $$(ip route | tail -n -1 | awk '{print $$3}') \
		-j MASQUERADE

	#关闭tap
	sudo ip link set dev ${TAP_L1} down

	#关闭dhcp服务
	sudo kill -TERM $$(cat ${PWD}/dnsmasq_l1.pid)

	#删除tap
	sudo ip tuntap del ${TAP_L1} mode tap

	#关闭ip转发
	sudo sysctl -w net.ipv4.ip_forward=0

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
				-c "apt update && apt install -y gdb git make network-manager pciutils strace wget"; \
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

run_l1:
	${PWD}/qemu/build/qemu-system-x86_64 \
		${QEMU_OPTIONS_L0} \
		-nographic

submodules:
	git submodule
		update \
		--init \
		--progress \
		--jobs 4
