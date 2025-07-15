PWD						:= $(shell pwd)
NPROC					:= $(shell nproc)
NET_PREFIX				:= 172.192.168
NET_MASK				:= 24
BUSYBOX 				:= busybox-1.37.0
DROPBEAR				:= dropbear-2024.85
SHARE_TAG 				:= share9p
USER 					:= $(shell whoami)
SSH_CONNECTION_ATTEMPTS := 5

ROOTFS_L1 				:= rootfs_l1
TAP_L0					:= tap0
L1_MAC					:= aa:bb:cc:cc:bb:aa
L1_IP					:= ${NET_PREFIX}.128
CONSOLE_L1_PORT			:= 1234
GDB_KERNEL_L1_PORT		:= 1235
define QEMU_OPTIONS_L1
       -cpu host \
       -smp 4 \
       -m 4G \
       -kernel ${PWD}/kernel/arch/x86_64/boot/bzImage \
       -append "rdinit=/sbin/init panic=-1 console=ttyS0 nokaslr" \
       -initrd ${PWD}/${ROOTFS_L1}.cpio \
       -netdev tap,id=net,ifname=${TAP_L0},script=no,downscript=no \
       -device virtio-net-pci,netdev=net \
       -fsdev local,id=share,path=${PWD},security_model=none \
       -device virtio-9p-pci,fsdev=share,mount_tag=${SHARE_TAG} \
       -enable-kvm \
       -nographic -no-reboot
endef #define QEMU_OPTIONS_L1

ROOTFS_L2 				:= rootfs_l2
BRIDGE_L1				:= br1
TAP_L1					:= tap1
L2_MAC					:= cc:bb:aa:aa:bb:cc
L2_IP					:= ${NET_PREFIX}.129
define QEMU_OPTIONS_L2
	-cpu host \
	-smp 2 \
	-m 2G \
	-L ${PWD}/qemu/pc-bios \
	-kernel ${PWD}/kernel/arch/x86_64/boot/bzImage \
	-append "rdinit=/sbin/init panic=-1 console=ttyS0 nokaslr" \
	-initrd ${PWD}/${ROOTFS_L2}.cpio \
	-netdev tap,id=net,ifname=${TAP_L1},script=no,downscript=no \
	-device virtio-net-pci,mac=${L2_MAC},netdev=net \
	-enable-kvm \
	-nographic -no-reboot
endef #define QEMU_OPTIONS_L2

BRIDGE_MIGRATE 			:= br_migrate
NET_MIGRATE_PREFIX		:= 172.192.169
NET_MIGRATE_MASK		:= 24

ROOTFS_SRC				:= rootfs_src
TAP_SRC					:= tap_src
SRC_MAC					:= aa:aa:cc:cc:aa:aa
SRC_IP					:= ${NET_MIGRATE_PREFIX}.130
CONSOLE_SRC_PORT		:= 1236
GDB_KERNEL_SRC_PORT		:= 1237
GDB_QEMU_SRC_SYNC_PORT  := 1234

ROOTFS_DST				:= rootfs_dst
TAP_DST					:= tap_dst
DST_MAC					:= cc:aa:aa:aa:aa:cc
DST_IP					:= ${NET_MIGRATE_PREFIX}.131
CONSOLE_DST_PORT		:= 1238
GDB_KERNEL_DST_PORT		:= 1249
GDB_QEMU_DST_SYNC_PORT  := 1234

ROOTFS_MIGRATE_GUEST	:= rootfs_migrate_guest
CONSOLE_MIGRATE_GUEST_PORT:= 1235

.PHONY: build kernel libvirt qemu rootfs_dst rootfs_l1 rootfs_l2 rootfs_migrate_guest rootfs_src submodules \
		fini_env gdb_libvirtd init_env \
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
	sudo ip tuntap add name ${TAP_L0} mode tap || exit 0
	sudo ip tuntap add name ${TAP_SRC} mode tap || exit 0
	sudo ip tuntap add name ${TAP_DST} mode tap || exit 0

	#添加子网
	sudo ip addr add ${NET_PREFIX}.1/${NET_MASK} dev ${TAP_L0} || exit 0
	sudo ip addr add ${NET_MIGRATE_PREFIX}.1/${NET_MIGRATE_MASK} dev ${BRIDGE_MIGRATE} || exit 0

	#启动dhcp服务
	sudo dnsmasq \
		--interface=${TAP_L0},${BRIDGE_MIGRATE} \
		--bind-interfaces \
		--dhcp-range=${NET_PREFIX}.2,${NET_PREFIX}.254 \
		--dhcp-range=${NET_MIGRATE_PREFIX}.2,${NET_MIGRATE_PREFIX}.254 \
		--dhcp-host=${L1_MAC},${L1_IP} \
		--dhcp-host=${L2_MAC},${L2_IP} \
		--dhcp-host=${SRC_MAC},${SRC_IP} \
		--dhcp-host=${DST_MAC},${DST_IP} \
		-x ${PWD}/dnsmasq.pid || exit 0

	#启动tap
	sudo ip link set dev ${TAP_L0} up || exit 0
	sudo ip link set dev ${TAP_SRC} up || exit 0
	sudo ip link set dev ${TAP_DST} up || exit 0

	#启动bridge
	sudo ip link set dev ${BRIDGE_MIGRATE} up || exit 0

	#添加tap到bridge
	sudo ip link set dev ${TAP_SRC} master ${BRIDGE_MIGRATE} || exit 0
	sudo ip link set dev ${TAP_DST} master ${BRIDGE_MIGRATE} || exit 0

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
		-i ${TAP_L0} \
		-o $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-j ACCEPT || exit 0
	sudo iptables -I FORWARD \
		-i $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-o ${TAP_L0} \
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

fini_env:
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
		-o ${TAP_L0} \
		-j ACCEPT || exit 0
	sudo iptables -D FORWARD \
		-i ${TAP_L0} \
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
	sudo ip link set dev ${TAP_DST} nomaster || exit 0
	sudo ip link set dev ${TAP_SRC} nomaster || exit 0

	#关闭bridge
	sudo ip link set dev ${BRIDGE_MIGRATE} down || exit 0

	#关闭tap
	sudo ip link set dev ${TAP_DST} down || exit 0
	sudo ip link set dev ${TAP_SRC} down || exit 0
	sudo ip link set dev ${TAP_L0} down || exit 0

	#关闭dhcp服务
	sudo kill -TERM $$(cat ${PWD}/dnsmasq.pid) || exit 0

	#删除tap
	sudo ip tuntap del ${TAP_DST} mode tap || exit 0
	sudo ip tuntap del ${TAP_SRC} mode tap || exit 0
	sudo ip tuntap del ${TAP_L0} mode tap || exit 0

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
				${QEMU_OPTIONS_L1} \
				-monitor none \
				-serial telnet::${CONSOLE_L1_PORT},server,nowait \
				-gdb tcp::${GDB_KERNEL_L1_PORT} -S

	gnome-terminal \
		--title "gdb for l1 kernel" \
		-- \
		gdb \
			-iex "set confirm on" \
			--init-eval-command="add-auto-load-safe-path ${PWD}/kernel/scripts/gdb/vmlinux-gdb.py" \
			--eval-command="target remote localhost:${GDB_KERNEL_L1_PORT}" \
			--eval-command="hbreak start_kernel" \
			--eval-command="continue" \
			${PWD}/kernel/vmlinux

init_l1:
	${PWD}/libvirt/build/tools/virsh undefine l1 || exit 0

	cp ${PWD}/l1.example.xml ${PWD}/l1.xml
	sed -i "s|{NAME}|l1|" ${PWD}/l1.xml
	sed -i "s|{KERNEL}|${PWD}/kernel/arch/x86_64/boot/bzImage|" ${PWD}/l1.xml
	sed -i "s|{INITRD}|${PWD}/${ROOTFS_L1}.cpio|" ${PWD}/l1.xml
	sed -i "s|{QEMU}|${PWD}/qemu/build/qemu-system-x86_64|" ${PWD}/l1.xml
	sed -i "s|{TAP}|${TAP_L0}|" ${PWD}/l1.xml
	sed -i "s|{SHARE_HOST}|${PWD}|" ${PWD}/l1.xml
	sed -i "s|{SHARE_TAG}|${SHARE_TAG}|" ${PWD}/l1.xml
	sed -i "s|{CONSOLE_PORT}|${CONSOLE_L1_PORT}|" ${PWD}/l1.xml
	sed -i "s|{GDB_PORT}|${GDB_KERNEL_L1_PORT}|" ${PWD}/l1.xml
	${PWD}/libvirt/build/tools/virsh define ${PWD}/l1.xml || exit 0

	${PWD}/libvirt/build/tools/virsh start l1 || exit 0

fini_l1:
	${PWD}/libvirt/build/tools/virsh destroy l1 || exit 0

run_l2:
	${PWD}/qemu/build/qemu-system-x86_64 \
		${QEMU_OPTIONS_L2}

gdb_kernel_l1:
	gnome-terminal \
		--title "gdb for l1 kernel" \
		-- \
		gdb \
			-iex "set confirm on" \
			--init-eval-command="add-auto-load-safe-path ${PWD}/kernel/scripts/gdb/vmlinux-gdb.py" \
			--eval-command="target remote localhost:${GDB_KERNEL_L1_PORT}" \
			${PWD}/kernel/vmlinux

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
		telnet localhost ${CONSOLE_L1_PORT}

ssh_l1:
	gnome-terminal \
		--title "ssh for l1" \
		-- \
		ssh \
			-o "StrictHostKeyChecking=no" \
			-o "ConnectionAttempts=${SSH_CONNECTION_ATTEMPTS}" \
			root@${L1_IP}

ssh_l2:
	gnome-terminal \
		--title "ssh for l2" \
		-- \
		ssh \
			-o "StrictHostKeyChecking=no" \
			-o "ConnectionAttempts=${SSH_CONNECTION_ATTEMPTS}" \
			root@${L2_IP}

build: kernel libvirt qemu rootfs_dst rootfs_l1 rootfs_l2 rootfs_migrate_guest rootfs_src
	@echo -e '\033[0;32m[*]\033[0mbuild the mqemu environment'

kernel:
	if [ ! -f "${PWD}/kernel/vmlinux" ]; then \
		sudo sed -i -E 's|# (deb-src)|\1|g' /etc/apt/sources.list && \
		sudo apt update && \
		sudo apt build-dep -y linux; \
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
		sudo apt install -y libjson-c-dev; \
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
		sudo apt install -y python3-pip; \
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
				-c "apt update && apt install -y bash-completion gdb git libfdt-dev libglib2.0-dev libpixman-1-dev make openssh-server pciutils strace wget"; \
		\
		#设置网卡 \
		echo "iface enp0s3 inet manual" | sudo tee ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/enp0s3.interface; \
		echo "up ip link set dev enp0s3 up" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/enp0s3.interface; \
		echo "down ip link set dev enp0s3 down" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/enp0s3.interface; \
		\
		#设置tap \
		echo "iface ${TAP_L1} inet manual" | sudo tee ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${TAP_L1}.interface; \
		echo "pre-up ip tuntap add name ${TAP_L1} mode tap" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${TAP_L1}.interface; \
		echo "up ip link set dev ${TAP_L1} up" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${TAP_L1}.interface; \
		echo "down ip link set dev ${TAP_L1} down" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${TAP_L1}.interface; \
		echo "post-down ip tuntap del ${TAP_L1} mode tap" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${TAP_L1}.interface; \
		\
		#设置bridge \
		echo "auto ${BRIDGE_L1}" | sudo tee ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "iface ${BRIDGE_L1} inet manual" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "pre-up ip link add name ${BRIDGE_L1} type bridge" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "pre-up ip link set dev ${BRIDGE_L1} address ${L1_MAC}" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "up ifup enp0s3" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "up ip link set dev enp0s3 master ${BRIDGE_L1}" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "up ifup ${TAP_L1}" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "up ip link set dev ${TAP_L1} master ${BRIDGE_L1}" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "up ip link set dev ${BRIDGE_L1} up" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "post-up dhclient -i ${BRIDGE_L1}" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "pre-down dhclient -r ${BRIDGE_L1}" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "down ip link set dev ${BRIDGE_L1} down" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "down ip link set dev ${TAP_L1} nomaster" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "down ifdown ${TAP_L1}" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "down ip link set dev enp0s3 nomaster" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "down ifdown enp0s3" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "post-down ip link del ${BRIDGE_L1} type bridge" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		\
		#开启ip转发 \
		sudo sed -i "s|^#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|" ${PWD}/${ROOTFS_L1}/etc/sysctl.conf; \
		\
		#设置ssh服务器 \
		sudo sed -i "s|^#PermitEmptyPasswords no|PermitEmptyPasswords yes|" ${PWD}/${ROOTFS_L1}/etc/ssh/sshd_config; \
		sudo sed -i "s|^#PermitRootLogin prohibit-password|PermitRootLogin yes|" ${PWD}/${ROOTFS_L1}/etc/ssh/sshd_config; \
		\
		#设置mqemu文件夹 \
		echo "${SHARE_TAG} /root 9p trans=virtio 0 0" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/fstab; \
		\
		#设置主机名称 \
		echo "l1" | sudo tee ${PWD}/${ROOTFS_L1}/etc/hostname; \
		\
		#设置密码 \
		sudo chroot ${PWD}/${ROOTFS_L1} /bin/bash -c "passwd -d root"; \
	fi

	cd ${PWD}/${ROOTFS_L1} && \
	sudo find . | sudo cpio -o --format=newc -F ${PWD}/${ROOTFS_L1}.cpio >/dev/null

	@echo -e '\033[0;32m[*]\033[0mbuild the l1 rootfs'

rootfs_l2:
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

	if [ ! -d ${PWD}/${ROOTFS_L2} ]; then \
		mkdir -p ${PWD}/${ROOTFS_L2}/dev/pts \
			${PWD}/${ROOTFS_L2}/etc/dropbear \
			${PWD}/${ROOTFS_L2}/etc/init.d \
			${PWD}/${ROOTFS_L2}/home/root \
			${PWD}/${ROOTFS_L2}/proc \
			${PWD}/${ROOTFS_L2}/sys \
			${PWD}/${ROOTFS_L2}/usr/share/udhcp; \
		\
		touch ${PWD}/${ROOTFS_L2}/etc/passwd \
			${PWD}/${ROOTFS_L2}/etc/group; \
		\
		make -C ${PWD}/${BUSYBOX} CONFIG_PREFIX=${PWD}/${ROOTFS_L2} install; \
		make -C ${PWD}/${DROPBEAR} install DESTDIR=${PWD}/${ROOTFS_L2}; \
		\
		#设置udhcpc \
		cp ${PWD}/${BUSYBOX}/examples/udhcp/simple.script ${PWD}/${ROOTFS_L2}/usr/share/udhcp/default.script; \
		\
		#设置inittab文件 \
		echo "::sysinit:/etc/init.d/rcS" | sudo tee ${PWD}/${ROOTFS_L2}/etc/inittab; \
		echo "ttyS0::respawn:/bin/sh" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/inittab; \
		\
		#设置初始化脚本 \
		echo "#!/bin/sh" | sudo tee ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "mount -a" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "/sbin/mdev -s" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "/sbin/ip link set dev eth0 address ${L2_MAC}" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "/sbin/syslogd -K" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "/sbin/udhcpc -i eth0 -s /usr/share/udhcp/default.script -S" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "/usr/sbin/addgroup -S -g 0 root" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "/usr/sbin/adduser -S -u 0 -G root -s /bin/sh -D root" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "/usr/bin/passwd -d root" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "/usr/local/sbin/dropbear -BRp 22" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		sudo chmod +x ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		\
		#设置挂载文件信息 \
		echo "devpts /dev/pts devpts defaults 0 0" | sudo tee ${PWD}/${ROOTFS_L2}/etc/fstab; \
		echo "proc /proc proc defaults 0 0" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/fstab; \
		echo "sysfs /sys sysfs defaults 0 0" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/fstab; \
	fi

	cd ${PWD}/${ROOTFS_L2} && \
	sudo find . | sudo cpio -o --format=newc -F ${PWD}/${ROOTFS_L2}.cpio >/dev/null

	@echo -e '\033[0;32m[*]\033[0mbuild the l2 rootfs'

rootfs_src:
	if [ ! -d ${PWD}/${ROOTFS_SRC} ]; then \
		sudo apt update && \
		sudo apt install -y \
			debootstrap; \
		\
		sudo debootstrap \
			--components=main,contrib,non-free,non-free-firmware \
			stable \
			${PWD}/${ROOTFS_SRC} \
			https://mirrors.tuna.tsinghua.edu.cn/debian/; \
		\
		sudo chroot \
			${PWD}/${ROOTFS_SRC} \
			/bin/bash \
				-c "apt update && apt install -y bash-completion gdb libfdt1 libglib2.0-0 libpixman-1-0 make netcat-openbsd openssh-server"; \
		\
		#设置网卡 \
		echo "auto enp0s3" | sudo tee ${PWD}/${ROOTFS_SRC}/etc/network/interfaces.d/enp0s3.interface; \
		echo "iface enp0s3 inet manual" | sudo tee -a ${PWD}/${ROOTFS_SRC}/etc/network/interfaces.d/enp0s3.interface; \
		echo "up ip link set dev enp0s3 up" | sudo tee -a ${PWD}/${ROOTFS_SRC}/etc/network/interfaces.d/enp0s3.interface; \
		echo "post-up dhclient -i enp0s3" | sudo tee -a ${PWD}/${ROOTFS_SRC}/etc/network/interfaces.d/enp0s3.interface; \
		echo "pre-down dhclient -r enp0s3" | sudo tee -a ${PWD}/${ROOTFS_SRC}/etc/network/interfaces.d/enp0s3.interface; \
		echo "down ip link set dev enp0s3 down" | sudo tee -a ${PWD}/${ROOTFS_SRC}/etc/network/interfaces.d/enp0s3.interface; \
		\
		#设置ssh服务器 \
		sudo sed -i "s|^#PermitEmptyPasswords no|PermitEmptyPasswords yes|" ${PWD}/${ROOTFS_SRC}/etc/ssh/sshd_config; \
		sudo sed -i "s|^#PermitRootLogin prohibit-password|PermitRootLogin yes|" ${PWD}/${ROOTFS_SRC}/etc/ssh/sshd_config; \
		\
		#设置mqemu文件夹 \
		sudo chroot ${PWD}/${ROOTFS_SRC} /bin/bash -c "useradd -m -G kvm -s /bin/bash ${USER} && passwd -d ${USER}"; \
		sudo chroot ${PWD}/${ROOTFS_SRC} su ${USER} -c "mkdir -p ${PWD}"; \
		echo "${SHARE_TAG} ${PWD} 9p trans=virtio 0 0" | sudo tee -a ${PWD}/${ROOTFS_SRC}/etc/fstab; \
		\
		#设置主机名称 \
		echo "src" | sudo tee ${PWD}/${ROOTFS_SRC}/etc/hostname; \
		\
		#设置root密码 \
		sudo chroot ${PWD}/${ROOTFS_SRC} /bin/bash -c "passwd -d root"; \
		\
		#设置libvirtd \
		sudo sed -i "4i export PATH=${PWD}/libvirt/build/src:\$$PATH" ${PWD}/${ROOTFS_SRC}/home/${USER}/.bashrc; \
		echo "[Unit]" | sudo tee ${PWD}/${ROOTFS_SRC}/etc/systemd/system/libvirtd.service; \
		echo "Description=libvirt daemon" | sudo tee -a ${PWD}/${ROOTFS_SRC}/etc/systemd/system/libvirtd.service; \
		echo "[Service]" | sudo tee -a ${PWD}/${ROOTFS_SRC}/etc/systemd/system/libvirtd.service; \
		echo "User=${USER}" | sudo tee -a ${PWD}/${ROOTFS_SRC}/etc/systemd/system/libvirtd.service; \
		echo "PAMName=login" | sudo tee -a ${PWD}/${ROOTFS_SRC}/etc/systemd/system/libvirtd.service; \
		echo "ExecStart=${PWD}/libvirt/build/src/libvirtd" | sudo tee -a ${PWD}/${ROOTFS_SRC}/etc/systemd/system/libvirtd.service; \
		echo "[Install]" | sudo tee -a ${PWD}/${ROOTFS_SRC}/etc/systemd/system/libvirtd.service; \
		echo "WantedBy=multi-user.target" | sudo tee -a ${PWD}/${ROOTFS_SRC}/etc/systemd/system/libvirtd.service; \
		sudo chroot ${PWD}/${ROOTFS_SRC} /bin/bash -c "systemctl enable libvirtd"; \
	fi

	cd ${PWD}/${ROOTFS_SRC} && \
	sudo find . | sudo cpio -o --format=newc -F ${PWD}/${ROOTFS_SRC}.cpio >/dev/null

	@echo -e '\033[0;32m[*]\033[0mbuild the src rootfs'

rootfs_dst:
	if [ ! -d ${PWD}/${ROOTFS_DST} ]; then \
		sudo apt update && \
		sudo apt install -y \
			debootstrap; \
		\
		sudo debootstrap \
			--components=main,contrib,non-free,non-free-firmware \
			stable \
			${PWD}/${ROOTFS_DST} \
			https://mirrors.tuna.tsinghua.edu.cn/debian/; \
		\
		sudo chroot \
			${PWD}/${ROOTFS_DST} \
			/bin/bash \
				-c "apt update && apt install -y bash-completion gdb libfdt1 libglib2.0-0 libpixman-1-0 make netcat-openbsd openssh-server"; \
		\
		#设置网卡 \
		echo "auto enp0s3" | sudo tee ${PWD}/${ROOTFS_DST}/etc/network/interfaces.d/enp0s3.interface; \
		echo "iface enp0s3 inet manual" | sudo tee -a ${PWD}/${ROOTFS_DST}/etc/network/interfaces.d/enp0s3.interface; \
		echo "up ip link set dev enp0s3 up" | sudo tee -a ${PWD}/${ROOTFS_DST}/etc/network/interfaces.d/enp0s3.interface; \
		echo "post-up dhclient -i enp0s3" | sudo tee -a ${PWD}/${ROOTFS_DST}/etc/network/interfaces.d/enp0s3.interface; \
		echo "pre-down dhclient -r enp0s3" | sudo tee -a ${PWD}/${ROOTFS_DST}/etc/network/interfaces.d/enp0s3.interface; \
		echo "down ip link set dev enp0s3 down" | sudo tee -a ${PWD}/${ROOTFS_DST}/etc/network/interfaces.d/enp0s3.interface; \
		\
		#设置ssh服务器 \
		sudo sed -i "s|^#PermitEmptyPasswords no|PermitEmptyPasswords yes|" ${PWD}/${ROOTFS_DST}/etc/ssh/sshd_config; \
		sudo sed -i "s|^#PermitRootLogin prohibit-password|PermitRootLogin yes|" ${PWD}/${ROOTFS_DST}/etc/ssh/sshd_config; \
		\
		#设置mqemu文件夹 \
		sudo chroot ${PWD}/${ROOTFS_DST} /bin/bash -c "useradd -m -G kvm -s /bin/bash ${USER} && passwd -d ${USER}"; \
		sudo chroot ${PWD}/${ROOTFS_DST} su ${USER} -c "mkdir -p ${PWD}"; \
		echo "${SHARE_TAG} ${PWD} 9p trans=virtio 0 0" | sudo tee -a ${PWD}/${ROOTFS_DST}/etc/fstab; \
		\
		#设置主机名称 \
		echo "dst" | sudo tee ${PWD}/${ROOTFS_DST}/etc/hostname; \
		\
		#设置root密码 \
		sudo chroot ${PWD}/${ROOTFS_DST} /bin/bash -c "passwd -d root"; \
		\
		#设置libvirtd \
		sudo sed -i "4i export PATH=${PWD}/libvirt/build/src:\$$PATH" ${PWD}/${ROOTFS_DST}/home/${USER}/.bashrc; \
		echo "[Unit]" | sudo tee ${PWD}/${ROOTFS_DST}/etc/systemd/system/libvirtd.service; \
		echo "Description=libvirt daemon" | sudo tee -a ${PWD}/${ROOTFS_DST}/etc/systemd/system/libvirtd.service; \
		echo "[Service]" | sudo tee -a ${PWD}/${ROOTFS_DST}/etc/systemd/system/libvirtd.service; \
		echo "User=${USER}" | sudo tee -a ${PWD}/${ROOTFS_DST}/etc/systemd/system/libvirtd.service; \
		echo "PAMName=login" | sudo tee -a ${PWD}/${ROOTFS_DST}/etc/systemd/system/libvirtd.service; \
		echo "ExecStart=${PWD}/libvirt/build/src/libvirtd" | sudo tee -a ${PWD}/${ROOTFS_DST}/etc/systemd/system/libvirtd.service; \
		echo "[Install]" | sudo tee -a ${PWD}/${ROOTFS_DST}/etc/systemd/system/libvirtd.service; \
		echo "WantedBy=multi-user.target" | sudo tee -a ${PWD}/${ROOTFS_DST}/etc/systemd/system/libvirtd.service; \
		sudo chroot ${PWD}/${ROOTFS_DST} /bin/bash -c "systemctl enable libvirtd"; \
	fi

	cd ${PWD}/${ROOTFS_DST} && \
	sudo find . | sudo cpio -o --format=newc -F ${PWD}/${ROOTFS_DST}.cpio >/dev/null

	@echo -e '\033[0;32m[*]\033[0mbuild the dst rootfs'

init_migrate:
	${PWD}/libvirt/build/tools/virsh undefine src || exit 0
	cp ${PWD}/migrate.example.xml ${PWD}/src.xml
	sed -i "s|{NAME}|src|" ${PWD}/src.xml
	sed -i "s|{KERNEL}|${PWD}/kernel/arch/x86_64/boot/bzImage|" ${PWD}/src.xml
	sed -i "s|{INITRD}|${PWD}/${ROOTFS_SRC}.cpio|" ${PWD}/src.xml
	sed -i "s|{QEMU}|${PWD}/qemu/build/qemu-system-x86_64|" ${PWD}/src.xml
	sed -i "s|{TAP}|${TAP_SRC}|" ${PWD}/src.xml
	sed -i "s|{MACADDRESS}|${SRC_MAC}|" ${PWD}/src.xml
	sed -i "s|{SHARE_HOST}|${PWD}|" ${PWD}/src.xml
	sed -i "s|{SHARE_TAG}|${SHARE_TAG}|" ${PWD}/src.xml
	sed -i "s|{CONSOLE_PORT}|${CONSOLE_SRC_PORT}|" ${PWD}/src.xml
	sed -i "s|{GDB_PORT}|${GDB_KERNEL_SRC_PORT}|" ${PWD}/src.xml
	${PWD}/libvirt/build/tools/virsh define ${PWD}/src.xml || exit 0
	${PWD}/libvirt/build/tools/virsh start src || exit 0

	${PWD}/libvirt/build/tools/virsh undefine dst || exit 0
	cp ${PWD}/migrate.example.xml ${PWD}/dst.xml
	sed -i "s|{NAME}|dst|" ${PWD}/dst.xml
	sed -i "s|{KERNEL}|${PWD}/kernel/arch/x86_64/boot/bzImage|" ${PWD}/dst.xml
	sed -i "s|{INITRD}|${PWD}/${ROOTFS_DST}.cpio|" ${PWD}/dst.xml
	sed -i "s|{QEMU}|${PWD}/qemu/build/qemu-system-x86_64|" ${PWD}/dst.xml
	sed -i "s|{TAP}|${TAP_DST}|" ${PWD}/dst.xml
	sed -i "s|{MACADDRESS}|${DST_MAC}|" ${PWD}/dst.xml
	sed -i "s|{SHARE_HOST}|${PWD}|" ${PWD}/dst.xml
	sed -i "s|{SHARE_TAG}|${SHARE_TAG}|" ${PWD}/dst.xml
	sed -i "s|{CONSOLE_PORT}|${CONSOLE_DST_PORT}|" ${PWD}/dst.xml
	sed -i "s|{GDB_PORT}|${GDB_KERNEL_DST_PORT}|" ${PWD}/dst.xml
	${PWD}/libvirt/build/tools/virsh define ${PWD}/dst.xml || exit 0
	${PWD}/libvirt/build/tools/virsh start dst || exit 0

console_src:
	gnome-terminal \
		--title "console for src" \
		-- \
		telnet localhost ${CONSOLE_SRC_PORT}

ssh_src:
	gnome-terminal \
		--title "ssh for src" \
		-- \
		ssh \
			-o "StrictHostKeyChecking=no" \
			-o "ConnectionAttempts=${SSH_CONNECTION_ATTEMPTS}" \
			root@${SRC_IP}

console_dst:
	gnome-terminal \
		--title "console for dst" \
		-- \
		telnet localhost ${CONSOLE_DST_PORT}

ssh_dst:
	gnome-terminal \
		--title "ssh for dst" \
		-- \
		ssh \
			-o "StrictHostKeyChecking=no" \
			-o "ConnectionAttempts=${SSH_CONNECTION_ATTEMPTS}" \
			root@${DST_IP}

fini_migrate:
	${PWD}/libvirt/build/tools/virsh destroy src || exit 0
	${PWD}/libvirt/build/tools/virsh undefine src || exit 0

	${PWD}/libvirt/build/tools/virsh destroy dst || exit 0
	${PWD}/libvirt/build/tools/virsh undefine dst || exit 0

rootfs_migrate_guest:
	if [ ! -d ${PWD}/${BUSYBOX} ]; then \
		wget https://busybox.net/downloads/${BUSYBOX}.tar.bz2; \
		tar -jxvf ${PWD}/${BUSYBOX}.tar.bz2; \
		make -C ${PWD}/${BUSYBOX} defconfig; \
		sed -i 's|^# \(CONFIG_STATIC\).*$$|\1=y|' ${PWD}/${BUSYBOX}/.config; \
		make -C ${PWD}/${BUSYBOX} -j ${NPROC}; \
	fi

	if [ ! -d ${PWD}/${ROOTFS_MIGRATE_GUEST} ]; then \
		mkdir -p ${PWD}/${ROOTFS_MIGRATE_GUEST}/dev/pts \
			${PWD}/${ROOTFS_MIGRATE_GUEST}/etc/init.d \
			${PWD}/${ROOTFS_MIGRATE_GUEST}/home/root \
			${PWD}/${ROOTFS_MIGRATE_GUEST}/proc \
			${PWD}/${ROOTFS_MIGRATE_GUEST}/sys \
		\
		touch ${PWD}/${ROOTFS_MIGRATE_GUEST}/etc/passwd \
			${PWD}/${ROOTFS_MIGRATE_GUEST}/etc/group; \
		\
		make -C ${PWD}/${BUSYBOX} CONFIG_PREFIX=${PWD}/${ROOTFS_MIGRATE_GUEST} install; \
		make -C ${PWD}/${DROPBEAR} install DESTDIR=${PWD}/${ROOTFS_MIGRATE_GUEST}; \
		\
		#设置inittab文件 \
		echo "::sysinit:/etc/init.d/rcS" | sudo tee ${PWD}/${ROOTFS_MIGRATE_GUEST}/etc/inittab; \
		echo "ttyS0::respawn:/bin/sh" | sudo tee -a ${PWD}/${ROOTFS_MIGRATE_GUEST}/etc/inittab; \
		\
		#设置初始化脚本 \
		echo "#!/bin/sh" | sudo tee ${PWD}/${ROOTFS_MIGRATE_GUEST}/etc/init.d/rcS; \
		echo "mount -a" | sudo tee -a ${PWD}/${ROOTFS_MIGRATE_GUEST}/etc/init.d/rcS; \
		echo "/sbin/mdev -s" | sudo tee -a ${PWD}/${ROOTFS_MIGRATE_GUEST}/etc/init.d/rcS; \
		echo "/usr/sbin/addgroup -S -g 0 root" | sudo tee -a ${PWD}/${ROOTFS_MIGRATE_GUEST}/etc/init.d/rcS; \
		echo "/usr/sbin/adduser -S -u 0 -G root -s /bin/sh -D root" | sudo tee -a ${PWD}/${ROOTFS_MIGRATE_GUEST}/etc/init.d/rcS; \
		echo "/usr/bin/passwd -d root" | sudo tee -a ${PWD}/${ROOTFS_MIGRATE_GUEST}/etc/init.d/rcS; \
		sudo chmod +x ${PWD}/${ROOTFS_MIGRATE_GUEST}/etc/init.d/rcS; \
		\
		#设置挂载文件信息 \
		echo "devpts /dev/pts devpts defaults 0 0" | sudo tee ${PWD}/${ROOTFS_MIGRATE_GUEST}/etc/fstab; \
		echo "proc /proc proc defaults 0 0" | sudo tee -a ${PWD}/${ROOTFS_MIGRATE_GUEST}/etc/fstab; \
		echo "sysfs /sys sysfs defaults 0 0" | sudo tee -a ${PWD}/${ROOTFS_MIGRATE_GUEST}/etc/fstab; \
	fi

	cd ${PWD}/${ROOTFS_MIGRATE_GUEST} && \
	sudo find . | sudo cpio -o --format=newc -F ${PWD}/${ROOTFS_MIGRATE_GUEST}.cpio >/dev/null
	sudo chown $$USER:$$USER ${PWD}/${ROOTFS_MIGRATE_GUEST}.cpio

	@echo -e '\033[0;32m[*]\033[0mbuild the migrate guest rootfs'

console_src_guest:
	gnome-terminal \
		--title "console for src guest" \
		-- \
		telnet ${SRC_IP} ${CONSOLE_MIGRATE_GUEST_PORT}

console_dst_guest:
	gnome-terminal \
		--title "console for dst guest" \
		-- \
		telnet ${DST_IP} ${CONSOLE_MIGRATE_GUEST_PORT}

migrate:
	#设置guest的xml
	cp ${PWD}/migrate_guest.example.xml ${PWD}/migrate_guest.xml
	sed -i "s|{NAME}|migrate_guest|" ${PWD}/migrate_guest.xml
	sed -i "s|{KERNEL}|${PWD}/kernel/arch/x86_64/boot/bzImage|" ${PWD}/migrate_guest.xml
	sed -i "s|{INITRD}|${PWD}/${ROOTFS_MIGRATE_GUEST}.cpio|" ${PWD}/migrate_guest.xml
	sed -i "s|{QEMU}|${PWD}/qemu/build/qemu-system-x86_64|" ${PWD}/migrate_guest.xml
	sed -i "s|{CONSOLE_PORT}|${CONSOLE_MIGRATE_GUEST_PORT}|" ${PWD}/migrate_guest.xml

	#启动src上libvirtd的gdb
	gnome-terminal \
		--title "gdb for src libvirtd" \
		-- \
		ssh \
			-o "StrictHostKeyChecking no" \
			-o "ConnectionAttempts=${SSH_CONNECTION_ATTEMPTS}" \
			-t \
			${USER}@${SRC_IP} \
			'echo "break virCommandHandshakeNotify" > wait_to_gdb_qemu && \
			echo "  command" >> wait_to_gdb_qemu && \
			echo "    silent" >> wait_to_gdb_qemu && \
			echo "    shell echo | nc -W 1 ${SRC_IP} ${GDB_QEMU_SRC_SYNC_PORT}" >> wait_to_gdb_qemu && \
			echo "    continue" >> wait_to_gdb_qemu && \
			echo "  end" >> wait_to_gdb_qemu && \
			gdb \
				-iex "set confirm on" \
				-iex "set pagination off" \
				-ex "set follow-fork-mode parent" \
				-x wait_to_gdb_qemu \
				-p $$(cat $$XDG_RUNTIME_DIR/libvirt/libvirtd.pid)'

	#启动src上qemu的gdb
	gnome-terminal \
		--title "gdb for src qemu" \
		-- \
		ssh \
			-o "StrictHostKeyChecking no" \
			-o "ConnectionAttempts=${SSH_CONNECTION_ATTEMPTS}" \
			-t \
			${USER}@${SRC_IP} \
			'nc -W 1 -l ${GDB_QEMU_SRC_SYNC_PORT} && \
			gdb \
				-iex "set confirm on" \
				-iex "set pagination off" \
				-ex "handle SIGUSR1 noprint" \
				--init-eval-command="source ${PWD}/qemu/scripts/qemu-gdb.py" \
				-p $$(cat $$XDG_RUNTIME_DIR/libvirt/qemu/run/migrate_guest.pid)'

	#启动dst上libvirtd的gdb
	gnome-terminal \
		--title "gdb for dst libvirtd" \
		-- \
		ssh \
			-o "StrictHostKeyChecking no" \
			-o "ConnectionAttempts=${SSH_CONNECTION_ATTEMPTS}" \
			-t \
			${USER}@${DST_IP} \
			'echo "break virCommandHandshakeNotify" > wait_to_gdb_qemu && \
			echo "  command" >> wait_to_gdb_qemu && \
			echo "    silent" >> wait_to_gdb_qemu && \
			echo "    shell echo | nc -W 1 ${DST_IP} ${GDB_QEMU_DST_SYNC_PORT}" >> wait_to_gdb_qemu && \
			echo "    continue" >> wait_to_gdb_qemu && \
			echo "  end" >> wait_to_gdb_qemu && \
			gdb \
				-iex "set confirm on" \
				-iex "set pagination off" \
				-ex "set follow-fork-mode parent" \
				-x wait_to_gdb_qemu \
				-p $$(cat $$XDG_RUNTIME_DIR/libvirt/libvirtd.pid)'

	#启动dst上qemu的gdb
	gnome-terminal \
		--title "gdb for dst qemu" \
		-- \
		ssh \
			-o "StrictHostKeyChecking no" \
			-o "ConnectionAttempts=${SSH_CONNECTION_ATTEMPTS}" \
			-t \
			${USER}@${DST_IP} \
			'nc -W 1 -l ${GDB_QEMU_DST_SYNC_PORT} && \
			gdb \
				-iex "set confirm on" \
				-iex "set pagination off" \
				-ex "handle SIGUSR1 noprint" \
				--init-eval-command="source ${PWD}/qemu/scripts/qemu-gdb.py" \
				-p $$(cat $$XDG_RUNTIME_DIR/libvirt/qemu/run/migrate_guest.pid)'

	#启动src的guest
	${PWD}/libvirt/build/tools/virsh -c qemu+ssh://${USER}@${SRC_IP}/session?no_verify=1 destroy migrate_guest || exit 0
	${PWD}/libvirt/build/tools/virsh -c qemu+ssh://${USER}@${SRC_IP}/session?no_verify=1 undefine migrate_guest || exit 0
	${PWD}/libvirt/build/tools/virsh -c qemu+ssh://${USER}@${SRC_IP}/session?no_verify=1 define ${PWD}/migrate_guest.xml || exit 0
	${PWD}/libvirt/build/tools/virsh -c qemu+ssh://${USER}@${SRC_IP}/session?no_verify=1 start migrate_guest || exit 0

	#热迁移
	${PWD}/libvirt/build/tools/virsh -c qemu+ssh://${USER}@${DST_IP}/session?no_verify=1 destroy migrate_guest || exit 0
	${PWD}/libvirt/build/tools/virsh -c qemu+ssh://${USER}@${DST_IP}/session?no_verify=1 undefine migrate_guest || exit 0
	${PWD}/libvirt/build/tools/virsh -c qemu+ssh://${USER}@${SRC_IP}/session?no_verify=1 migrate --live migrate_guest qemu+ssh://${USER}@${DST_IP}/session?no_verify=1 || exit 0

submodules:
	git submodule \
		update \
		--init \
		--progress \
		--jobs 4
