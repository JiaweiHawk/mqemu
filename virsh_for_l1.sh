#!/bin/sh

XDG_RUNTIME_DIR=${PWD}/runtime ${PWD}/libvirt/build/tools/virsh $@
