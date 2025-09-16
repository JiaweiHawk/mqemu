PWD						:= $(shell pwd)
NPROC					:= $(shell nproc)
NET_PREFIX				:= 172.192.168
NET_MASK				:= 24
BUSYBOX 				:= busybox-1.37.0
DROPBEAR				:= dropbear-2024.85
SHARE_TAG 				:= share9p
USER 					:= $(shell whoami)
SSH_CONNECTION_ATTEMPTS := 5

ROOTFS_FOR_L1 			:= rootfs_for_l1
TAP_FOR_L1				:= tap_for_l1
MAC_FOR_L1				:= aa:bb:cc:cc:bb:aa
IP_FOR_L1				:= ${NET_PREFIX}.128
CONSOLE_PORT_FOR_L1		:= 1234
GDB_KERNEL_PORT_FOR_L1	:= 1235
define QEMU_OPTIONS_FOR_L1
       -cpu host \
       -smp 4 \
       -m 4G \
       -kernel ${PWD}/kernel/arch/x86_64/boot/bzImage \
       -append "rdinit=/sbin/init panic=-1 console=ttyS0 nokaslr" \
       -initrd ${PWD}/${ROOTFS_FOR_L1}.cpio \
       -netdev tap,id=net,ifname=${TAP_FOR_L1},script=no,downscript=no \
       -device virtio-net-pci,netdev=net \
       -fsdev local,id=share,path=${PWD},security_model=none \
       -device virtio-9p-pci,fsdev=share,mount_tag=${SHARE_TAG} \
       -enable-kvm \
       -nographic -no-reboot
endef #define QEMU_OPTIONS_FOR_L1

ROOTFS_FOR_L2 			:= rootfs_for_l2
BRIDGE_L1				:= br_l1
TAP_FOR_L2				:= tap_for_l2
MAC_FOR_L2				:= cc:bb:aa:aa:bb:cc
IP_FOR_L2				:= ${NET_PREFIX}.129
define QEMU_OPTIONS_FOR_L2
	-cpu host \
	-smp 2 \
	-m 2G \
	-L ${PWD}/qemu/pc-bios \
	-kernel ${PWD}/kernel/arch/x86_64/boot/bzImage \
	-append "rdinit=/sbin/init panic=-1 console=ttyS0 nokaslr" \
	-initrd ${PWD}/${ROOTFS_FOR_L2}.cpio \
	-netdev tap,id=net,ifname=${TAP_FOR_L2},script=no,downscript=no \
	-device virtio-net-pci,mac=${MAC_FOR_L2},netdev=net \
	-enable-kvm \
	-nographic -no-reboot
endef #define QEMU_OPTIONS_FOR_L2

BRIDGE_MIGRATE 			:= br_migrate
NET_MIGRATE_PREFIX		:= 172.192.169
NET_MIGRATE_MASK		:= 24

ROOTFS_FOR_SRC			:= rootfs_for_src
TAP_FOR_SRC				:= tap_for_src
MAC_FOR_SRC				:= aa:aa:cc:cc:aa:aa
IP_FOR_SRC				:= ${NET_MIGRATE_PREFIX}.130
CONSOLE_PORT_FOR_SRC	:= 1236
GDB_KERNEL_PORT_FOR_SRC	:= 1237
GDB_QEMU_PORT_FOR_SRC  	:= 1234

ROOTFS_FOR_DST			:= rootfs_for_dst
TAP_FOR_DST				:= tap_for_dst
MAC_FOR_DST				:= cc:aa:aa:aa:aa:cc
IP_FOR_DST				:= ${NET_MIGRATE_PREFIX}.131
CONSOLE_PORT_FOR_DST	:= 1238
GDB_KERNEL_PORT_FOR_DST	:= 1249
GDB_QEMU_PORT_FOR_DST  	:= 1234

QEMU_MIGRATE_GUEST_PATH := ${PWD}/qemu-system-x86_64

ROOTFS_FOR_MIGRATE_GUEST:= rootfs_for_migrate_guest
CONSOLE_MIGRATE_PORT_FOR_GUEST:= 1235

.PHONY: build kernel libvirt qemu rootfs_for_dst rootfs_for_l1 rootfs_for_l2 rootfs_for_migrate_guest rootfs_for_src submodules \
		debug_libvirt fini_env gdb_libvirtd init_env \
		console_l1 debug_l1 fini_l1 gdb_kernel_l1 gdb_qemu_l1 init_l1 ssh_l1 \
		run_l2 ssh_l2 \
		console_src console_dst fini_migrate init_migrate ssh_src ssh_dst \
		console_src_guest console_dst_guest migrate

init_env:
	#开启ip转发
	sudo sysctl -w net.ipv4.ip_forward=1 || exit 0

	#创建bridge
	sudo ip link add ${BRIDGE_MIGRATE} type bridge || exit 0

	#创建tap
	sudo ip tuntap add name ${TAP_FOR_L1} mode tap || exit 0
	sudo ip tuntap add name ${TAP_FOR_SRC} mode tap || exit 0
	sudo ip tuntap add name ${TAP_FOR_DST} mode tap || exit 0

	#添加子网
	sudo ip addr add ${NET_PREFIX}.1/${NET_MASK} dev ${TAP_FOR_L1} || exit 0
	sudo ip addr add ${NET_MIGRATE_PREFIX}.1/${NET_MIGRATE_MASK} dev ${BRIDGE_MIGRATE} || exit 0

	#启动dhcp服务
	sudo dnsmasq \
		--interface=${TAP_FOR_L1},${BRIDGE_MIGRATE} \
		--bind-interfaces \
		--dhcp-range=${NET_PREFIX}.2,${NET_PREFIX}.254 \
		--dhcp-range=${NET_MIGRATE_PREFIX}.2,${NET_MIGRATE_PREFIX}.254 \
		--dhcp-host=${MAC_FOR_L1},${IP_FOR_L1} \
		--dhcp-host=${MAC_FOR_L2},${IP_FOR_L2} \
		--dhcp-host=${MAC_FOR_SRC},${IP_FOR_SRC} \
		--dhcp-host=${MAC_FOR_DST},${IP_FOR_DST} \
		-x ${PWD}/dnsmasq.pid || exit 0

	#启动tap
	sudo ip link set dev ${TAP_FOR_L1} up || exit 0
	sudo ip link set dev ${TAP_FOR_SRC} up || exit 0
	sudo ip link set dev ${TAP_FOR_DST} up || exit 0

	#启动bridge
	sudo ip link set dev ${BRIDGE_MIGRATE} up || exit 0

	#添加tap到bridge
	sudo ip link set dev ${TAP_FOR_SRC} master ${BRIDGE_MIGRATE} || exit 0
	sudo ip link set dev ${TAP_FOR_DST} master ${BRIDGE_MIGRATE} || exit 0

	#添加NAT规则
	sudo iptables -t nat -A POSTROUTING \
		-s ${NET_PREFIX}.0/${NET_MASK} \
		-o $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-j MASQUERADE || exit 0
	sudo iptables -t nat -A POSTROUTING \
		-s ${NET_MIGRATE_PREFIX}.0/${NET_MIGRATE_MASK} \
		-o $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-j MASQUERADE || exit 0

	#添加FORWARD规则
	sudo iptables -I FORWARD \
		-i ${TAP_FOR_L1} \
		-o $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-j ACCEPT || exit 0
	sudo iptables -I FORWARD \
		-i $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-o ${TAP_FOR_L1} \
		-j ACCEPT || exit 0
	sudo iptables -I FORWARD \
		-i ${BRIDGE_MIGRATE} \
		-o $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-j ACCEPT || exit 0
	sudo iptables -I FORWARD \
		-i $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-o ${BRIDGE_MIGRATE} \
		-j ACCEPT || exit 0

	#启动libvirtd
	${PWD}/libvirt/build/src/libvirtd -d || exit 0

	@echo -e '\033[0;32m[*]\033[0minit the environment'

fini_env: fini_l1 fini_migrate
	#结束libvirtd
	kill -s TERM $$(cat $$XDG_RUNTIME_DIR/libvirt/libvirtd.pid) || exit 0

	#删除FORWARD规则
	sudo iptables -D FORWARD \
		-i $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-o ${BRIDGE_MIGRATE} \
		-j ACCEPT || exit 0
	sudo iptables -D FORWARD \
		-i ${BRIDGE_MIGRATE} \
		-o $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-j ACCEPT || exit 0
	sudo iptables -D FORWARD \
		-i $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-o ${TAP_FOR_L1} \
		-j ACCEPT || exit 0
	sudo iptables -D FORWARD \
		-i ${TAP_FOR_L1} \
		-o $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-j ACCEPT || exit 0

	#删除NAT规则
	sudo iptables -t nat -D POSTROUTING \
		-s ${NET_MIGRATE_PREFIX}.0/${NET_MIGRATE_MASK} \
		-o $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-j MASQUERADE || exit 0
	sudo iptables -t nat -D POSTROUTING \
		-s ${NET_PREFIX}.0/${NET_MASK} \
		-o $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-j MASQUERADE || exit 0

	#从bridge删除tap
	sudo ip link set dev ${TAP_FOR_DST} nomaster || exit 0
	sudo ip link set dev ${TAP_FOR_SRC} nomaster || exit 0

	#关闭bridge
	sudo ip link set dev ${BRIDGE_MIGRATE} down || exit 0

	#关闭tap
	sudo ip link set dev ${TAP_FOR_DST} down || exit 0
	sudo ip link set dev ${TAP_FOR_SRC} down || exit 0
	sudo ip link set dev ${TAP_FOR_L1} down || exit 0

	#关闭dhcp服务
	sudo kill -TERM $$(cat ${PWD}/dnsmasq.pid) || exit 0

	#删除tap
	sudo ip tuntap del ${TAP_FOR_DST} mode tap || exit 0
	sudo ip tuntap del ${TAP_FOR_SRC} mode tap || exit 0
	sudo ip tuntap del ${TAP_FOR_L1} mode tap || exit 0

	#删除bridge
	sudo ip link del name ${BRIDGE_MIGRATE} type bridge || exit 0

	#关闭ip转发
	sudo sysctl -w net.ipv4.ip_forward=0 || exit 0

	@echo -e '\033[0;32m[*]\033[0mfini the environment'

debug_l1:
	gnome-terminal \
		--title "gdb for l1 qemu" \
		-- \
		gdb \
			-iex "set confirm on" \
			-ex "handle SIGUSR1 noprint" \
			--init-eval-command="source ${PWD}/qemu/scripts/qemu-gdb.py" \
			--args \
				${PWD}/qemu/build/qemu-system-x86_64 \
				${QEMU_OPTIONS_FOR_L1} \
				-monitor none \
				-serial telnet::${CONSOLE_PORT_FOR_L1},server,nowait \
				-gdb tcp::${GDB_KERNEL_PORT_FOR_L1} -S

	gnome-terminal \
		--title "gdb for l1 kernel" \
		-- \
		gdb \
			-iex "set confirm on" \
			--init-eval-command="add-auto-load-safe-path ${PWD}/kernel/scripts/gdb/vmlinux-gdb.py" \
			--eval-command="set tcp connect-timeout unlimited" \
			--eval-command="target remote localhost:${GDB_KERNEL_PORT_FOR_L1}" \
			--eval-command="hbreak start_kernel" \
			--eval-command="continue" \
			${PWD}/kernel/vmlinux

init_l1:
	${PWD}/libvirt/build/tools/virsh undefine l1 || exit 0

	cp ${PWD}/l1.example.xml ${PWD}/l1.xml
	sed -i "s|{NAME}|l1|" ${PWD}/l1.xml
	sed -i "s|{KERNEL}|${PWD}/kernel/arch/x86_64/boot/bzImage|" ${PWD}/l1.xml
	sed -i "s|{INITRD}|${PWD}/${ROOTFS_FOR_L1}.cpio|" ${PWD}/l1.xml
	sed -i "s|{QEMU}|${PWD}/qemu/build/qemu-system-x86_64|" ${PWD}/l1.xml
	sed -i "s|{TAP}|${TAP_FOR_L1}|" ${PWD}/l1.xml
	sed -i "s|{SHARE_HOST}|${PWD}|" ${PWD}/l1.xml
	sed -i "s|{SHARE_TAG}|${SHARE_TAG}|" ${PWD}/l1.xml
	sed -i "s|{CONSOLE_PORT}|${CONSOLE_PORT_FOR_L1}|" ${PWD}/l1.xml
	sed -i "s|{GDB_PORT}|${GDB_KERNEL_PORT_FOR_L1}|" ${PWD}/l1.xml
	${PWD}/libvirt/build/tools/virsh define ${PWD}/l1.xml || exit 0

	${PWD}/libvirt/build/tools/virsh start l1 || exit 0

fini_l1:
	${PWD}/libvirt/build/tools/virsh destroy l1 || exit 0

run_l2:
	${PWD}/qemu/build/qemu-system-x86_64 \
		${QEMU_OPTIONS_FOR_L2}

gdb_kernel_l1:
	gnome-terminal \
		--title "gdb for l1 kernel" \
		-- \
		gdb \
			-iex "set confirm on" \
			--init-eval-command="add-auto-load-safe-path ${PWD}/kernel/scripts/gdb/vmlinux-gdb.py" \
			--eval-command="set tcp connect-timeout unlimited" \
			--eval-command="target remote localhost:${GDB_KERNEL_PORT_FOR_L1}" \
			${PWD}/kernel/vmlinux

debug_libvirt:
	gnome-terminal \
		--title "gdb for libvirt" \
		-- \
		gdb \
			-iex "set confirm on" \
			-ex "set follow-fork-mode parent" \
			--args ${PWD}/libvirt/build/src/libvirtd

gdb_libvirtd:
	gnome-terminal \
		--title "gdb for libvirtd" \
		-- \
		gdb \
			-iex "set confirm on" \
			-ex "set follow-fork-mode parent" \
			-p $$(cat $$XDG_RUNTIME_DIR/libvirt/libvirtd.pid)

gdb_qemu_l1:
	gnome-terminal \
		--title "gdb for l1 qemu" \
		-- \
		gdb \
			-iex "set confirm on" \
			-ex "handle SIGUSR1 noprint" \
			--init-eval-command="source ${PWD}/qemu/scripts/qemu-gdb.py" \
			--pid=$$(cat $$XDG_RUNTIME_DIR/libvirt/qemu/run/l1.pid)

console_l1:
	gnome-terminal \
		--title "console for l1" \
		-- \
		telnet localhost ${CONSOLE_PORT_FOR_L1}

ssh_l1:
	gnome-terminal \
		--title "ssh for l1" \
		-- \
		ssh \
			-o "StrictHostKeyChecking=no" \
			-o "ConnectionAttempts=${SSH_CONNECTION_ATTEMPTS}" \
			root@${IP_FOR_L1}

ssh_l2:
	gnome-terminal \
		--title "ssh for l2" \
		-- \
		ssh \
			-o "StrictHostKeyChecking=no" \
			-o "ConnectionAttempts=${SSH_CONNECTION_ATTEMPTS}" \
			root@${IP_FOR_L2}

build: kernel libvirt qemu rootfs_for_dst rootfs_for_l1 rootfs_for_l2 rootfs_for_migrate_guest rootfs_for_src
	@echo -e '\033[0;32m[*]\033[0mbuild the mqemu environment'

kernel:
	if [ ! -f "${PWD}/kernel/vmlinux" ]; then \
		sudo sed -i -E 's|# (deb-src)|\1|g' /etc/apt/sources.list && \
		sudo apt update && \
		sudo apt build-dep -y linux && \
		sudo apt install -y bear; \
		\
		make \
			-C ${PWD}/kernel \
			defconfig; \
		\
		${PWD}/kernel/scripts/config \
			--file ${PWD}/kernel/.config \
			-e CONFIG_DEBUG_INFO_DWARF5 \
			-e CONFIG_GDB_SCRIPTS \
			-e CONFIG_X86_X2APIC \
			-e CONFIG_KVM \
			-e CONFIG_$(shell lsmod | grep "^kvm_" | awk '{print $$1}') \
			-e CONFIG_TUN \
			-e CONFIG_BRIDGE; \
		\
		yes "" | make \
			-C ${PWD}/kernel \
			oldconfig; \
	fi

	bear \
		--append \
		--output ${PWD}/compile_commands.json \
		-- make \
			-C ${PWD}/kernel \
			-j ${NPROC}

	@echo -e '\033[0;32m[*]\033[0mbuild the linux kernel'

libvirt:
	if [ ! -d ${PWD}/libvirt/build ]; then \
		sudo sed -i -E 's|# (deb-src)|\1|g' /etc/apt/sources.list && \
		sudo apt update && \
		sudo apt build-dep -y libvirt && \
		sudo apt install -y bear libjson-c-dev; \
		\
		meson setup ${PWD}/libvirt/build ${PWD}/libvirt; \
		meson configure ${PWD}/libvirt/build --auto-features disabled -Ddriver_remote=enabled -Ddriver_libvirtd=enabled -Ddriver_qemu=enabled -Djson_c=enabled; \
		\
	fi

	bear \
		--append \
		--output ${PWD}/compile_commands.json \
		-- ninja -C ${PWD}/libvirt/build

	@echo -e '\033[0;32m[*]\033[0mbuild the libvirt'

qemu:
	if [ ! -d "${PWD}/qemu/build" ]; then \
		sudo sed -i -E 's|# (deb-src)|\1|g' /etc/apt/sources.list && \
		sudo apt update && \
		sudo apt build-dep -y qemu && \
		sudo apt install -y bear python3-pip; \
		\
		cd ${PWD}/qemu && \
		./configure \
			--target-list=x86_64-softmmu \
			--without-default-features \
			--enable-debug \
			--enable-kvm \
			--enable-attr \
			--enable-virtfs; \
	fi

	bear \
		--append \
		--output ${PWD}/compile_commands.json \
		-- make \
			-C ${PWD}/qemu \
			-j ${NPROC}

	@echo -e '\033[0;32m[*]\033[0mbuild the qemu'

rootfs_for_l1:
	if [ ! -d ${PWD}/${ROOTFS_FOR_L1} ]; then \
		sudo apt update && \
		sudo apt install -y \
			debootstrap; \
		\
		sudo debootstrap \
			--components=main,contrib,non-free,non-free-firmware \
			stable \
			${PWD}/${ROOTFS_FOR_L1} \
			https://mirrors.tuna.tsinghua.edu.cn/debian/; \
		\
		sudo chroot \
			${PWD}/${ROOTFS_FOR_L1} \
			/bin/bash \
				-c "apt update && apt install -y bash-completion gdb git isc-dhcp-client libfdt-dev libglib2.0-dev libpixman-1-dev make openssh-server pciutils strace wget"; \
		\
		#设置网卡 \
		echo "iface enp0s3 inet manual" | sudo tee ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/enp0s3.interface; \
		echo "up ip link set dev enp0s3 up" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/enp0s3.interface; \
		echo "down ip link set dev enp0s3 down" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/enp0s3.interface; \
		\
		#设置tap \
		echo "iface ${TAP_FOR_L2} inet manual" | sudo tee ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${TAP_FOR_L2}.interface; \
		echo "pre-up ip tuntap add name ${TAP_FOR_L2} mode tap" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${TAP_FOR_L2}.interface; \
		echo "up ip link set dev ${TAP_FOR_L2} up" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${TAP_FOR_L2}.interface; \
		echo "down ip link set dev ${TAP_FOR_L2} down" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${TAP_FOR_L2}.interface; \
		echo "post-down ip tuntap del ${TAP_FOR_L2} mode tap" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${TAP_FOR_L2}.interface; \
		\
		#设置bridge \
		echo "auto ${BRIDGE_L1}" | sudo tee ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "iface ${BRIDGE_L1} inet manual" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "pre-up ip link add name ${BRIDGE_L1} type bridge" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "pre-up ip link set dev ${BRIDGE_L1} address ${MAC_FOR_L1}" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "up ifup enp0s3" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "up ip link set dev enp0s3 master ${BRIDGE_L1}" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "up ifup ${TAP_FOR_L2}" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "up ip link set dev ${TAP_FOR_L2} master ${BRIDGE_L1}" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "up ip link set dev ${BRIDGE_L1} up" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "post-up dhclient -i ${BRIDGE_L1}" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "pre-down dhclient -r ${BRIDGE_L1}" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "down ip link set dev ${BRIDGE_L1} down" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "down ip link set dev ${TAP_FOR_L2} nomaster" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "down ifdown ${TAP_FOR_L2}" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "down ip link set dev enp0s3 nomaster" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "down ifdown enp0s3" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "post-down ip link del ${BRIDGE_L1} type bridge" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		\
		#开启ip转发 \
		sudo sed -i "s|^#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|" ${PWD}/${ROOTFS_FOR_L1}/etc/sysctl.conf; \
		\
		#设置ssh服务器 \
		sudo sed -i "s|^#PermitEmptyPasswords no|PermitEmptyPasswords yes|" ${PWD}/${ROOTFS_FOR_L1}/etc/ssh/sshd_config; \
		sudo sed -i "s|^#PermitRootLogin prohibit-password|PermitRootLogin yes|" ${PWD}/${ROOTFS_FOR_L1}/etc/ssh/sshd_config; \
		\
		#设置mqemu文件夹 \
		echo "${SHARE_TAG} /root 9p trans=virtio 0 0" | sudo tee -a ${PWD}/${ROOTFS_FOR_L1}/etc/fstab; \
		\
		#设置主机名称 \
		echo "l1" | sudo tee ${PWD}/${ROOTFS_FOR_L1}/etc/hostname; \
		\
		#设置密码 \
		sudo chroot ${PWD}/${ROOTFS_FOR_L1} /bin/bash -c "passwd -d root"; \
	fi

	cd ${PWD}/${ROOTFS_FOR_L1} && \
	sudo find . | sudo cpio -o --format=newc -F ${PWD}/${ROOTFS_FOR_L1}.cpio >/dev/null

	@echo -e '\033[0;32m[*]\033[0mbuild the rootfs for l1'

rootfs_for_l2:
	if [ ! -d ${PWD}/${BUSYBOX} ]; then \
		wget https://busybox.net/downloads/${BUSYBOX}.tar.bz2; \
		tar -jxvf ${PWD}/${BUSYBOX}.tar.bz2; \
		make -C ${PWD}/${BUSYBOX} defconfig; \
		sed -i 's|^# \(CONFIG_STATIC\).*$$|\1=y|' ${PWD}/${BUSYBOX}/.config; \
		make -C ${PWD}/${BUSYBOX} -j ${NPROC}; \
	fi

	if [ ! -d ${PWD}/${DROPBEAR} ]; then \
		sudo apt update && \
			sudo apt install -y autoconf; \
		wget https://dropbear.nl/mirror/releases/${DROPBEAR}.tar.bz2; \
		tar -jxvf ${PWD}/${DROPBEAR}.tar.bz2; \
		cd ${PWD}/${DROPBEAR} && \
			autoconf && \
			autoheader && \
			./configure \
				--disable-zlib --disable-harden \
				--enable-static && \
			make PROGRAMS="dropbear scp" && \
			make strip; \
	fi

	if [ ! -d ${PWD}/${ROOTFS_FOR_L2} ]; then \
		mkdir -p ${PWD}/${ROOTFS_FOR_L2}/dev/pts \
			${PWD}/${ROOTFS_FOR_L2}/etc/dropbear \
			${PWD}/${ROOTFS_FOR_L2}/etc/init.d \
			${PWD}/${ROOTFS_FOR_L2}/home/root \
			${PWD}/${ROOTFS_FOR_L2}/proc \
			${PWD}/${ROOTFS_FOR_L2}/sys \
			${PWD}/${ROOTFS_FOR_L2}/usr/share/udhcp; \
		\
		touch ${PWD}/${ROOTFS_FOR_L2}/etc/passwd \
			${PWD}/${ROOTFS_FOR_L2}/etc/group; \
		\
		make -C ${PWD}/${BUSYBOX} CONFIG_PREFIX=${PWD}/${ROOTFS_FOR_L2} install; \
		make -C ${PWD}/${DROPBEAR} install DESTDIR=${PWD}/${ROOTFS_FOR_L2}; \
		\
		#设置udhcpc \
		cp ${PWD}/${BUSYBOX}/examples/udhcp/simple.script ${PWD}/${ROOTFS_FOR_L2}/usr/share/udhcp/default.script; \
		\
		#设置inittab文件 \
		echo "::sysinit:/etc/init.d/rcS" | sudo tee ${PWD}/${ROOTFS_FOR_L2}/etc/inittab; \
		echo "ttyS0::respawn:/bin/sh" | sudo tee -a ${PWD}/${ROOTFS_FOR_L2}/etc/inittab; \
		\
		#设置初始化脚本 \
		echo "#!/bin/sh" | sudo tee ${PWD}/${ROOTFS_FOR_L2}/etc/init.d/rcS; \
		echo "mount -a" | sudo tee -a ${PWD}/${ROOTFS_FOR_L2}/etc/init.d/rcS; \
		echo "/sbin/mdev -s" | sudo tee -a ${PWD}/${ROOTFS_FOR_L2}/etc/init.d/rcS; \
		echo "/sbin/ip link set dev eth0 address ${MAC_FOR_L2}" | sudo tee -a ${PWD}/${ROOTFS_FOR_L2}/etc/init.d/rcS; \
		echo "/sbin/syslogd -K" | sudo tee -a ${PWD}/${ROOTFS_FOR_L2}/etc/init.d/rcS; \
		echo "/sbin/udhcpc -i eth0 -s /usr/share/udhcp/default.script -S" | sudo tee -a ${PWD}/${ROOTFS_FOR_L2}/etc/init.d/rcS; \
		echo "/usr/sbin/addgroup -S -g 0 root" | sudo tee -a ${PWD}/${ROOTFS_FOR_L2}/etc/init.d/rcS; \
		echo "/usr/sbin/adduser -S -u 0 -G root -s /bin/sh -D root" | sudo tee -a ${PWD}/${ROOTFS_FOR_L2}/etc/init.d/rcS; \
		echo "/usr/bin/passwd -d root" | sudo tee -a ${PWD}/${ROOTFS_FOR_L2}/etc/init.d/rcS; \
		echo "/usr/local/sbin/dropbear -BRp 22" | sudo tee -a ${PWD}/${ROOTFS_FOR_L2}/etc/init.d/rcS; \
		sudo chmod +x ${PWD}/${ROOTFS_FOR_L2}/etc/init.d/rcS; \
		\
		#设置挂载文件信息 \
		echo "devpts /dev/pts devpts defaults 0 0" | sudo tee ${PWD}/${ROOTFS_FOR_L2}/etc/fstab; \
		echo "proc /proc proc defaults 0 0" | sudo tee -a ${PWD}/${ROOTFS_FOR_L2}/etc/fstab; \
		echo "sysfs /sys sysfs defaults 0 0" | sudo tee -a ${PWD}/${ROOTFS_FOR_L2}/etc/fstab; \
	fi

	cd ${PWD}/${ROOTFS_FOR_L2} && \
	sudo find . | sudo cpio -o --format=newc -F ${PWD}/${ROOTFS_FOR_L2}.cpio >/dev/null

	@echo -e '\033[0;32m[*]\033[0mbuild the rootfs for l2'

rootfs_for_src:
	if [ ! -d ${PWD}/${ROOTFS_FOR_SRC} ]; then \
		sudo apt update && \
		sudo apt install -y \
			debootstrap; \
		\
		sudo debootstrap \
			--components=main,contrib,non-free,non-free-firmware \
			stable \
			${PWD}/${ROOTFS_FOR_SRC} \
			https://mirrors.tuna.tsinghua.edu.cn/debian/; \
		\
		sudo chroot \
			${PWD}/${ROOTFS_FOR_SRC} \
			/bin/bash \
				-c "apt update && apt install -y bash-completion gdb gdbserver isc-dhcp-client libfdt1 libglib2.0-0 libpixman-1-0 make netcat-openbsd openssh-server"; \
		\
		#设置网卡 \
		echo "auto enp0s3" | sudo tee ${PWD}/${ROOTFS_FOR_SRC}/etc/network/interfaces.d/enp0s3.interface; \
		echo "iface enp0s3 inet manual" | sudo tee -a ${PWD}/${ROOTFS_FOR_SRC}/etc/network/interfaces.d/enp0s3.interface; \
		echo "up ip link set dev enp0s3 up" | sudo tee -a ${PWD}/${ROOTFS_FOR_SRC}/etc/network/interfaces.d/enp0s3.interface; \
		echo "post-up dhclient -i enp0s3" | sudo tee -a ${PWD}/${ROOTFS_FOR_SRC}/etc/network/interfaces.d/enp0s3.interface; \
		echo "pre-down dhclient -r enp0s3" | sudo tee -a ${PWD}/${ROOTFS_FOR_SRC}/etc/network/interfaces.d/enp0s3.interface; \
		echo "down ip link set dev enp0s3 down" | sudo tee -a ${PWD}/${ROOTFS_FOR_SRC}/etc/network/interfaces.d/enp0s3.interface; \
		\
		#设置ssh服务器 \
		sudo sed -i "s|^#PermitEmptyPasswords no|PermitEmptyPasswords yes|" ${PWD}/${ROOTFS_FOR_SRC}/etc/ssh/sshd_config; \
		sudo sed -i "s|^#PermitRootLogin prohibit-password|PermitRootLogin yes|" ${PWD}/${ROOTFS_FOR_SRC}/etc/ssh/sshd_config; \
		\
		#设置mqemu文件夹 \
		sudo chroot ${PWD}/${ROOTFS_FOR_SRC} /bin/bash -c "useradd -m -G kvm -s /bin/bash ${USER} && passwd -d ${USER}"; \
		sudo chroot ${PWD}/${ROOTFS_FOR_SRC} su ${USER} -c "mkdir -p ${PWD}"; \
		echo "${SHARE_TAG} ${PWD} 9p trans=virtio 0 0" | sudo tee -a ${PWD}/${ROOTFS_FOR_SRC}/etc/fstab; \
		\
		#设置主机名称 \
		echo "src" | sudo tee ${PWD}/${ROOTFS_FOR_SRC}/etc/hostname; \
		\
		#设置root密码 \
		sudo chroot ${PWD}/${ROOTFS_FOR_SRC} /bin/bash -c "passwd -d root"; \
		\
		#设置libvirtd \
		sudo sed -i "4i export PATH=${PWD}/libvirt/build/src:\$$PATH" ${PWD}/${ROOTFS_FOR_SRC}/home/${USER}/.bashrc; \
		echo "[Unit]" | sudo tee ${PWD}/${ROOTFS_FOR_SRC}/etc/systemd/system/libvirtd.service; \
		echo "Description=libvirt daemon" | sudo tee -a ${PWD}/${ROOTFS_FOR_SRC}/etc/systemd/system/libvirtd.service; \
		echo "[Service]" | sudo tee -a ${PWD}/${ROOTFS_FOR_SRC}/etc/systemd/system/libvirtd.service; \
		echo "User=${USER}" | sudo tee -a ${PWD}/${ROOTFS_FOR_SRC}/etc/systemd/system/libvirtd.service; \
		echo "PAMName=login" | sudo tee -a ${PWD}/${ROOTFS_FOR_SRC}/etc/systemd/system/libvirtd.service; \
		echo "ExecStart=${PWD}/libvirt/build/src/libvirtd" | sudo tee -a ${PWD}/${ROOTFS_FOR_SRC}/etc/systemd/system/libvirtd.service; \
		echo "[Install]" | sudo tee -a ${PWD}/${ROOTFS_FOR_SRC}/etc/systemd/system/libvirtd.service; \
		echo "WantedBy=multi-user.target" | sudo tee -a ${PWD}/${ROOTFS_FOR_SRC}/etc/systemd/system/libvirtd.service; \
		sudo chroot ${PWD}/${ROOTFS_FOR_SRC} /bin/bash -c "systemctl enable libvirtd"; \
	fi

	cd ${PWD}/${ROOTFS_FOR_SRC} && \
	sudo find . | sudo cpio -o --format=newc -F ${PWD}/${ROOTFS_FOR_SRC}.cpio >/dev/null

	@echo -e '\033[0;32m[*]\033[0mbuild the rootfs for src'

rootfs_for_dst:
	if [ ! -d ${PWD}/${ROOTFS_FOR_DST} ]; then \
		sudo apt update && \
		sudo apt install -y \
			debootstrap; \
		\
		sudo debootstrap \
			--components=main,contrib,non-free,non-free-firmware \
			stable \
			${PWD}/${ROOTFS_FOR_DST} \
			https://mirrors.tuna.tsinghua.edu.cn/debian/; \
		\
		sudo chroot \
			${PWD}/${ROOTFS_FOR_DST} \
			/bin/bash \
				-c "apt update && apt install -y bash-completion gdb gdbserver isc-dhcp-client libfdt1 libglib2.0-0 libpixman-1-0 make netcat-openbsd openssh-server"; \
		\
		#设置网卡 \
		echo "auto enp0s3" | sudo tee ${PWD}/${ROOTFS_FOR_DST}/etc/network/interfaces.d/enp0s3.interface; \
		echo "iface enp0s3 inet manual" | sudo tee -a ${PWD}/${ROOTFS_FOR_DST}/etc/network/interfaces.d/enp0s3.interface; \
		echo "up ip link set dev enp0s3 up" | sudo tee -a ${PWD}/${ROOTFS_FOR_DST}/etc/network/interfaces.d/enp0s3.interface; \
		echo "post-up dhclient -i enp0s3" | sudo tee -a ${PWD}/${ROOTFS_FOR_DST}/etc/network/interfaces.d/enp0s3.interface; \
		echo "pre-down dhclient -r enp0s3" | sudo tee -a ${PWD}/${ROOTFS_FOR_DST}/etc/network/interfaces.d/enp0s3.interface; \
		echo "down ip link set dev enp0s3 down" | sudo tee -a ${PWD}/${ROOTFS_FOR_DST}/etc/network/interfaces.d/enp0s3.interface; \
		\
		#设置ssh服务器 \
		sudo sed -i "s|^#PermitEmptyPasswords no|PermitEmptyPasswords yes|" ${PWD}/${ROOTFS_FOR_DST}/etc/ssh/sshd_config; \
		sudo sed -i "s|^#PermitRootLogin prohibit-password|PermitRootLogin yes|" ${PWD}/${ROOTFS_FOR_DST}/etc/ssh/sshd_config; \
		\
		#设置mqemu文件夹 \
		sudo chroot ${PWD}/${ROOTFS_FOR_DST} /bin/bash -c "useradd -m -G kvm -s /bin/bash ${USER} && passwd -d ${USER}"; \
		sudo chroot ${PWD}/${ROOTFS_FOR_DST} su ${USER} -c "mkdir -p ${PWD}"; \
		echo "${SHARE_TAG} ${PWD} 9p trans=virtio 0 0" | sudo tee -a ${PWD}/${ROOTFS_FOR_DST}/etc/fstab; \
		\
		#设置主机名称 \
		echo "dst" | sudo tee ${PWD}/${ROOTFS_FOR_DST}/etc/hostname; \
		\
		#设置root密码 \
		sudo chroot ${PWD}/${ROOTFS_FOR_DST} /bin/bash -c "passwd -d root"; \
		\
		#设置libvirtd \
		sudo sed -i "4i export PATH=${PWD}/libvirt/build/src:\$$PATH" ${PWD}/${ROOTFS_FOR_DST}/home/${USER}/.bashrc; \
		echo "[Unit]" | sudo tee ${PWD}/${ROOTFS_FOR_DST}/etc/systemd/system/libvirtd.service; \
		echo "Description=libvirt daemon" | sudo tee -a ${PWD}/${ROOTFS_FOR_DST}/etc/systemd/system/libvirtd.service; \
		echo "[Service]" | sudo tee -a ${PWD}/${ROOTFS_FOR_DST}/etc/systemd/system/libvirtd.service; \
		echo "User=${USER}" | sudo tee -a ${PWD}/${ROOTFS_FOR_DST}/etc/systemd/system/libvirtd.service; \
		echo "PAMName=login" | sudo tee -a ${PWD}/${ROOTFS_FOR_DST}/etc/systemd/system/libvirtd.service; \
		echo "ExecStart=${PWD}/libvirt/build/src/libvirtd" | sudo tee -a ${PWD}/${ROOTFS_FOR_DST}/etc/systemd/system/libvirtd.service; \
		echo "[Install]" | sudo tee -a ${PWD}/${ROOTFS_FOR_DST}/etc/systemd/system/libvirtd.service; \
		echo "WantedBy=multi-user.target" | sudo tee -a ${PWD}/${ROOTFS_FOR_DST}/etc/systemd/system/libvirtd.service; \
		sudo chroot ${PWD}/${ROOTFS_FOR_DST} /bin/bash -c "systemctl enable libvirtd"; \
	fi

	cd ${PWD}/${ROOTFS_FOR_DST} && \
	sudo find . | sudo cpio -o --format=newc -F ${PWD}/${ROOTFS_FOR_DST}.cpio >/dev/null

	@echo -e '\033[0;32m[*]\033[0mbuild the rootfs for dst'

init_migrate:
	${PWD}/libvirt/build/tools/virsh undefine src || exit 0
	cp ${PWD}/migrate.example.xml ${PWD}/src.xml
	sed -i "s|{NAME}|src|" ${PWD}/src.xml
	sed -i "s|{KERNEL}|${PWD}/kernel/arch/x86_64/boot/bzImage|" ${PWD}/src.xml
	sed -i "s|{INITRD}|${PWD}/${ROOTFS_FOR_SRC}.cpio|" ${PWD}/src.xml
	sed -i "s|{QEMU}|${PWD}/qemu/build/qemu-system-x86_64|" ${PWD}/src.xml
	sed -i "s|{TAP}|${TAP_FOR_SRC}|" ${PWD}/src.xml
	sed -i "s|{MACADDRESS}|${MAC_FOR_SRC}|" ${PWD}/src.xml
	sed -i "s|{SHARE_HOST}|${PWD}|" ${PWD}/src.xml
	sed -i "s|{SHARE_TAG}|${SHARE_TAG}|" ${PWD}/src.xml
	sed -i "s|{CONSOLE_PORT}|${CONSOLE_PORT_FOR_SRC}|" ${PWD}/src.xml
	sed -i "s|{GDB_PORT}|${GDB_KERNEL_PORT_FOR_SRC}|" ${PWD}/src.xml
	${PWD}/libvirt/build/tools/virsh define ${PWD}/src.xml || exit 0
	${PWD}/libvirt/build/tools/virsh start src || exit 0

	${PWD}/libvirt/build/tools/virsh undefine dst || exit 0
	cp ${PWD}/migrate.example.xml ${PWD}/dst.xml
	sed -i "s|{NAME}|dst|" ${PWD}/dst.xml
	sed -i "s|{KERNEL}|${PWD}/kernel/arch/x86_64/boot/bzImage|" ${PWD}/dst.xml
	sed -i "s|{INITRD}|${PWD}/${ROOTFS_FOR_DST}.cpio|" ${PWD}/dst.xml
	sed -i "s|{QEMU}|${PWD}/qemu/build/qemu-system-x86_64|" ${PWD}/dst.xml
	sed -i "s|{TAP}|${TAP_FOR_DST}|" ${PWD}/dst.xml
	sed -i "s|{MACADDRESS}|${MAC_FOR_DST}|" ${PWD}/dst.xml
	sed -i "s|{SHARE_HOST}|${PWD}|" ${PWD}/dst.xml
	sed -i "s|{SHARE_TAG}|${SHARE_TAG}|" ${PWD}/dst.xml
	sed -i "s|{CONSOLE_PORT}|${CONSOLE_PORT_FOR_DST}|" ${PWD}/dst.xml
	sed -i "s|{GDB_PORT}|${GDB_KERNEL_PORT_FOR_DST}|" ${PWD}/dst.xml
	${PWD}/libvirt/build/tools/virsh define ${PWD}/dst.xml || exit 0
	${PWD}/libvirt/build/tools/virsh start dst || exit 0

console_src:
	gnome-terminal \
		--title "console for src" \
		-- \
		telnet localhost ${CONSOLE_PORT_FOR_SRC}

ssh_src:
	gnome-terminal \
		--title "ssh for src" \
		-- \
		ssh \
			-o "StrictHostKeyChecking=no" \
			-o "ConnectionAttempts=${SSH_CONNECTION_ATTEMPTS}" \
			root@${IP_FOR_SRC}

console_dst:
	gnome-terminal \
		--title "console for dst" \
		-- \
		telnet localhost ${CONSOLE_PORT_FOR_DST}

ssh_dst:
	gnome-terminal \
		--title "ssh for dst" \
		-- \
		ssh \
			-o "StrictHostKeyChecking=no" \
			-o "ConnectionAttempts=${SSH_CONNECTION_ATTEMPTS}" \
			root@${IP_FOR_DST}

fini_migrate:
	${PWD}/libvirt/build/tools/virsh destroy src || exit 0
	${PWD}/libvirt/build/tools/virsh undefine src || exit 0

	${PWD}/libvirt/build/tools/virsh destroy dst || exit 0
	${PWD}/libvirt/build/tools/virsh undefine dst || exit 0

rootfs_for_migrate_guest:
	if [ ! -d ${PWD}/${BUSYBOX} ]; then \
		wget https://busybox.net/downloads/${BUSYBOX}.tar.bz2; \
		tar -jxvf ${PWD}/${BUSYBOX}.tar.bz2; \
		make -C ${PWD}/${BUSYBOX} defconfig; \
		sed -i 's|^# \(CONFIG_STATIC\).*$$|\1=y|' ${PWD}/${BUSYBOX}/.config; \
		make -C ${PWD}/${BUSYBOX} -j ${NPROC}; \
	fi

	if [ ! -d ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST} ]; then \
		mkdir -p ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/dev/pts \
			${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/etc/init.d \
			${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/home/root \
			${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/proc \
			${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/sys \
		\
		touch ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/etc/passwd \
			${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/etc/group; \
		\
		make -C ${PWD}/${BUSYBOX} CONFIG_PREFIX=${PWD}/${ROOTFS_FOR_MIGRATE_GUEST} install; \
		make -C ${PWD}/${DROPBEAR} install DESTDIR=${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}; \
		\
		#设置inittab文件 \
		echo "::sysinit:/etc/init.d/rcS" | sudo tee ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/etc/inittab; \
		echo "ttyS0::respawn:/bin/sh" | sudo tee -a ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/etc/inittab; \
		\
		#设置初始化脚本 \
		echo "#!/bin/sh" | sudo tee ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/etc/init.d/rcS; \
		echo "mount -a" | sudo tee -a ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/etc/init.d/rcS; \
		echo "/sbin/mdev -s" | sudo tee -a ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/etc/init.d/rcS; \
		echo "/usr/sbin/addgroup -S -g 0 root" | sudo tee -a ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/etc/init.d/rcS; \
		echo "/usr/sbin/adduser -S -u 0 -G root -s /bin/sh -D root" | sudo tee -a ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/etc/init.d/rcS; \
		echo "/usr/bin/passwd -d root" | sudo tee -a ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/etc/init.d/rcS; \
		sudo chmod +x ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/etc/init.d/rcS; \
		\
		#设置挂载文件信息 \
		echo "devpts /dev/pts devpts defaults 0 0" | sudo tee ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/etc/fstab; \
		echo "proc /proc proc defaults 0 0" | sudo tee -a ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/etc/fstab; \
		echo "sysfs /sys sysfs defaults 0 0" | sudo tee -a ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}/etc/fstab; \
	fi

	cd ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST} && \
	sudo find . | sudo cpio -o --format=newc -F ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}.cpio >/dev/null
	sudo chown $$USER:$$USER ${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}.cpio

	@echo -e '\033[0;32m[*]\033[0mbuild the rootfs for migrate guest'

console_src_guest:
	gnome-terminal \
		--title "console for src guest" \
		-- \
		telnet ${IP_FOR_SRC} ${CONSOLE_MIGRATE_PORT_FOR_GUEST}

console_dst_guest:
	gnome-terminal \
		--title "console for dst guest" \
		-- \
		telnet ${IP_FOR_DST} ${CONSOLE_MIGRATE_PORT_FOR_GUEST}

migrate:
	#设置qemu的gdbserver
	echo '#!/bin/sh' | tee ${QEMU_MIGRATE_GUEST_PATH}
	echo 'guest=$$(echo "$$@" | sed -n "s|.* guest=\([^,]*\).*|\1|p")' | tee -a ${QEMU_MIGRATE_GUEST_PATH}
	echo 'if [ "$$guest" = "" ]; then' | tee -a ${QEMU_MIGRATE_GUEST_PATH}
	echo 'exec ${PWD}/qemu/build/qemu-system-x86_64 "$$@"' | tee -a ${QEMU_MIGRATE_GUEST_PATH}
	echo 'else' | tee -a ${QEMU_MIGRATE_GUEST_PATH}
	echo 'exec gdbserver 0.0.0.0:${GDB_QEMU_PORT_FOR_SRC} ${PWD}/qemu/build/qemu-system-x86_64 "$$@"' | tee -a ${QEMU_MIGRATE_GUEST_PATH}
	echo 'fi' | tee -a ${QEMU_MIGRATE_GUEST_PATH}
	chmod +x ${QEMU_MIGRATE_GUEST_PATH}

	#设置guest的xml
	cp ${PWD}/migrate_guest.example.xml ${PWD}/migrate_guest.xml
	sed -i "s|{NAME}|migrate_guest|" ${PWD}/migrate_guest.xml
	sed -i "s|{KERNEL}|${PWD}/kernel/arch/x86_64/boot/bzImage|" ${PWD}/migrate_guest.xml
	sed -i "s|{INITRD}|${PWD}/${ROOTFS_FOR_MIGRATE_GUEST}.cpio|" ${PWD}/migrate_guest.xml
	sed -i "s|{QEMU}|${QEMU_MIGRATE_GUEST_PATH}|" ${PWD}/migrate_guest.xml
	sed -i "s|{CONSOLE_PORT}|${CONSOLE_MIGRATE_PORT_FOR_GUEST}|" ${PWD}/migrate_guest.xml

	#启动src上libvirtd的gdb
	gnome-terminal \
		--title "gdb for src libvirtd" \
		-- \
		ssh \
			-o "StrictHostKeyChecking no" \
			-o "ConnectionAttempts=${SSH_CONNECTION_ATTEMPTS}" \
			-t \
			${USER}@${IP_FOR_SRC} \
			'gdb \
				-iex "set confirm on" \
				-iex "set pagination off" \
				-ex "set follow-fork-mode parent" \
				-p $$(cat $$XDG_RUNTIME_DIR/libvirt/libvirtd.pid)'

	#启动src上qemu的gdb
	gnome-terminal \
		--title "gdb for src qemu" \
		-- \
		ssh \
			-o "StrictHostKeyChecking no" \
			-o "ConnectionAttempts=${SSH_CONNECTION_ATTEMPTS}" \
			-t \
			${USER}@${IP_FOR_SRC} \
			'gdb \
				-iex "set confirm on" \
				-iex "set pagination off" \
				-ex "handle SIGUSR1 noprint" \
				-ex "set tcp connect-timeout unlimited" \
				-ex "target remote localhost:${GDB_QEMU_PORT_FOR_SRC}" \
				--init-eval-command="source ${PWD}/qemu/scripts/qemu-gdb.py"'

	#启动dst上libvirtd的gdb
	gnome-terminal \
		--title "gdb for dst libvirtd" \
		-- \
		ssh \
			-o "StrictHostKeyChecking no" \
			-o "ConnectionAttempts=${SSH_CONNECTION_ATTEMPTS}" \
			-t \
			${USER}@${IP_FOR_DST} \
			'gdb \
				-iex "set confirm on" \
				-iex "set pagination off" \
				-ex "set follow-fork-mode parent" \
				-p $$(cat $$XDG_RUNTIME_DIR/libvirt/libvirtd.pid)'

	#启动dst上qemu的gdb
	gnome-terminal \
		--title "gdb for dst qemu" \
		-- \
		ssh \
			-o "StrictHostKeyChecking no" \
			-o "ConnectionAttempts=${SSH_CONNECTION_ATTEMPTS}" \
			-t \
			${USER}@${IP_FOR_DST} \
			'gdb \
				-iex "set confirm on" \
				-iex "set pagination off" \
				-ex "handle SIGUSR1 noprint" \
				-ex "set tcp connect-timeout unlimited" \
				-ex "target remote localhost:${GDB_QEMU_PORT_FOR_DST}" \
				--init-eval-command="source ${PWD}/qemu/scripts/qemu-gdb.py"'

	#启动src的guest
	${PWD}/libvirt/build/tools/virsh -c qemu+ssh://${USER}@${IP_FOR_SRC}/session?no_verify=1 destroy migrate_guest || exit 0
	${PWD}/libvirt/build/tools/virsh -c qemu+ssh://${USER}@${IP_FOR_SRC}/session?no_verify=1 undefine migrate_guest || exit 0
	${PWD}/libvirt/build/tools/virsh -c qemu+ssh://${USER}@${IP_FOR_SRC}/session?no_verify=1 define ${PWD}/migrate_guest.xml || exit 0
	${PWD}/libvirt/build/tools/virsh -c qemu+ssh://${USER}@${IP_FOR_SRC}/session?no_verify=1 start migrate_guest || exit 0

	#热迁移
	${PWD}/libvirt/build/tools/virsh -c qemu+ssh://${USER}@${IP_FOR_DST}/session?no_verify=1 destroy migrate_guest || exit 0
	${PWD}/libvirt/build/tools/virsh -c qemu+ssh://${USER}@${IP_FOR_DST}/session?no_verify=1 undefine migrate_guest || exit 0
	${PWD}/libvirt/build/tools/virsh -c qemu+ssh://${USER}@${IP_FOR_SRC}/session?no_verify=1 migrate --live migrate_guest qemu+ssh://${USER}@${IP_FOR_DST}/session?no_verify=1 || exit 0

submodules:
	git submodule \
		update \
		--init \
		--progress \
		--jobs 4
