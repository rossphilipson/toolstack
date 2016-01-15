#!/bin/bash

# Use this utility to setup NUMA node affinity on the OpenXT platform. To use
# it, copy this file and the numautil binary found in ../bin to a location on
# the OpenXT system (e.g. /storage). SELinux mush be disabled to use this:
#
# $ nr
# $ setenforcing 0
#
# If any of the VMs are NDVMs, the configuration files must be modified to
# allow the VMs configurations to be edited. This is done by editing
# /config/vms/00000000-0000-0000-0000-000000000002.db and setting
# "modify-vm-settings" to "true". After this is done the dbd must be told to
# reload settings like this:
#
# $ kill -SIGHUP <pid-of-dbd>
#
# Then setup the configuration below (Steps 1 and 2) for the system in
# question and run the script. Note this will change the system measurements
# too so a reseal will need to be done on reboot.

# Step 1:
#
# The following list specifies what NUMA node to set the VCPU affinity to for
# each of the listed VMs. This is just a sample configuration. The values are
# of the form VMName:NUMANode. Any VMs not listed will not have any node
# affinity set. The primary reason is to allow a guest to only use memory local
# to the CPUs in the node that the VM has affinity to. The second way this is
# useful is for device pass-through where PCIe devices have proximity to one
# node or another. E.g. most systems will have thier PCH have proximity to
# NUMA node 0 (since by default if there is only one processor package it will
# be in node 0). So it makes sense to assign the Network VM to that node since
# it has the integrated NICs assigned to it (those devices being on the PCI(e)
# bus on the PCH).
VMLIST=(Win7VM1:1 Win7VM2:1 Win7VM3:1 Win7VM4:1 Network:0
WinTPC1:0 WinTPC2:0 WinTPC3:0 WinTPC4:0 WinTPC5:0
WinTPC6:1 WinTPC7:1 WinTPC8:1 WinTPC9:1 WinTPC10:1)

# Step 2:
#
# Dom0 is a special case because it needs its VCPU affinity set at boot time.
# This is done using e.g. "dom0_max_vcpus=4 dom0_vcpus_pin" on the Xen command
# line. This says give dom0 4 VCPUs and pin them to the first 4 CPUs. Though
# this is a bit limiting it is mostly fine since dom0 is the domain where all
# the devices on the PCH live that are not passed through. So in this example,
# CPUs 0 - 3 are in NUMA node 0 where the PCH is connected. Setting this value
# to zero will prevent the utility from changing dom0's default configuration.
DOM0=4

# Use utility to get the CPU:NODE mapping for the system
CTON=(`./numautil -c`)

function form_affinity_param() {
     local value="cpus-affinity=$1:"
     local first=""

     for i in ${CTON[@]}; do
         cpu=$(echo $i | cut -d\: -f1)
         node=$(echo $i | cut -d\: -f2)

         if [ "$node" == "$2" ]; then
             if [ -z "$first" ]; then
                 value="$value$cpu"
                 first="no"
             else
                 value="$value,$cpu"
             fi
         fi
     done

     echo "$value"
}

function reset_extra_xenvm() {
    local value=""

    IFS=';' read -r -a subarr <<< "`xec-vm -n $1 get extra-xenvm`"

    for substr in "${subarr[@]}"
    do
        [[ "$substr" =~ "affinity" ]] && continue

        if [ -z "$value" ]; then
            value="$substr"
        else
            value+=";$substr"
        fi
    done

    xec-vm -n $1 set extra-xenvm "$value"
    echo "Reset VM $1 to value $value"
}

function set_extra_xenvm() {
    local value=`xec-vm -n $1 get extra-xenvm`
    local vcpu=0

    while [ $vcpu -lt $3 ]; do
        affinity=$(form_affinity_param $vcpu $2)

        if [ -z "$value" ]; then
            value="$affinity"
        else
            value+=";$affinity"
        fi
        vcpu=$[$vcpu+1]
    done

    xec-vm -n $1 set extra-xenvm "$value"
    echo "Setting VM $1 to value $value"
}

function setup_dom0_vcpus() {
    echo "Setup dom0 with $DOM0 vcpus"

    if [ $DOM0 -gt 0 ]; then
        [ ! -f /boot/system/grub/grub.orig ] && cp /boot/system/grub/grub.cfg /boot/system/grub/grub.orig

        cat /boot/system/grub/grub.cfg | sed 's/dom0_max_vcpus=[[:digit:]]\+ \?//g' | sed 's/dom0_vcpus_pin \?//g' > /boot/system/grub/tmp.cfg
        cat /boot/system/grub/tmp.cfg | sed "s/XEN_COMMON_CMD=\"/XEN_COMMON_CMD=\"dom0_max_vcpus=$DOM0 dom0_vcpus_pin /" > /boot/system/grub/grub.cfg
    fi
}

# Process the VM list
for i in ${VMLIST[@]}; do
     vm=$(echo $i | cut -d\: -f1)
     node=$(echo $i | cut -d\: -f2)
     vcpus=`xec-vm -n $vm get vcpus`
     [ $vcpus -lt 1 ] && vcpus=1
     echo "Setting node affinity for $vm with $vcpus vcpus to $node"
     # Reset the extra-xenvm node, remove all cpus-affinity settings
     reset_extra_xenvm $vm
     # Set the new CPU affinity configuration
     set_extra_xenvm $vm $node $vcpus
done

# Setup the new dom0 VCPU configuration, remove previous settings
setup_dom0_vcpus

