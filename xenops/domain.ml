(*
 * Copyright (C) 2006-2007 XenSource Ltd.
 * Copyright (C) 2008      Citrix Ltd.
 * Author Vincent Hanquez <vincent.hanquez@eu.citrix.com>
 * Author Dave Scott <dave.scott@eu.citrix.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
open Printf
open Stringext
open Listext
open Pervasiveext

open Device_common
include Domain_common
open D

type shutdown_reason = PowerOff | Reboot | Suspend | Crash | Halt | Unknown of int

(** Strings suitable for putting in the control/shutdown xenstore entry *)
let string_of_shutdown_reason = function
	| PowerOff -> "poweroff"
	| Reboot   -> "reboot"
	| Suspend  -> "suspend"
        | Crash    -> "crash" (* this one makes no sense to send to a guest *)
	| Halt     -> "halt"
	| Unknown x -> sprintf "(unknown %d)" x (* or this one *)

(** Decode the shutdown_reason contained within the dominfo struct *)
let shutdown_reason_of_int = function
	| 0 -> PowerOff
	| 1 -> Reboot
	| 2 -> Suspend
	| 3 -> Crash
	| 4 -> Halt
	| x -> Unknown x

let shutdown_to_xc_shutdown = function
	| PowerOff -> Xc.Poweroff
	| Reboot   -> Xc.Reboot
	| Suspend  -> Xc.Suspend
	| Crash    -> Xc.Crash
	| Halt     -> Xc.Halt
	| Unknown _-> raise (Invalid_argument "unknown")

(** Immediately change the domain state to shutdown *)
let hard_shutdown ~xc domid req = 
	Xc.domain_shutdown xc domid (shutdown_to_xc_shutdown req)

(** Return the path in xenstore watched by the PV shutdown driver *)
let control_shutdown ~xs domid = xs.Xs.getdomainpath domid ^ "/control/shutdown"

let hvm_shutdown ~xs domid = xs.Xs.getdomainpath domid ^ "/control/hvm-shutdown"

let gpe_enabled ~xs domid = xs.Xs.getdomainpath domid ^ "/control/hvm-powerbutton-enable"
(** Request a shutdown, return without waiting for acknowledgement *)
let shutdown ~xc ~xs ~hvm domid req =
	debug "Requesting shutdown of domain %d" domid;
	let reason = string_of_shutdown_reason req in
	xs.Xs.write (control_shutdown ~xs domid) reason;
	if hvm then (
		let has_pv_driver = Xc.hvm_check_pvdriver xc domid in
		let acpi_s_state = Xc.domain_get_acpi_s_state xc domid in
		let is_gpe_enabled = 
			try
				xs.Xs.read (gpe_enabled ~xs domid)
			with Xb.Noent ->
				"0"
		in
		(* If HVM domain is sleeping (according to acpi suspend state),
		   we shut it down here using the shutdown hypercall. otherwise we shut it down
		   with ACPI SCI from qemu to the guest. *)
		if (not has_pv_driver && acpi_s_state <> 0) || (is_gpe_enabled <> "1") then
			Xc.domain_shutdown xc domid (shutdown_to_xc_shutdown req)
		else if (not has_pv_driver) && (is_gpe_enabled = "1") then
			xs.Xs.write (hvm_shutdown ~xs domid) reason
		else
			debug "Handling shutdown of domain %d through PV driver." domid;
	)

(** PV domains will acknowledge the request by deleting the node from the
    store, block until this happens. *)
let shutdown_wait_for_ack ?timeout ~xs domid req =
	debug "Waiting for PV domain %d to acknowledge shutdown request" domid;
	let path = control_shutdown ~xs domid in
	try
		Watch.wait_for ~xs ?timeout (Watch.value_to_become path "");
		debug "Domain acknowledged shutdown request";
		true
	with Watch.Timeout _ ->
		debug "Timed-out waiting for domain to acknowledge shutdown request";
		false

let shutdown_ack ?(timeout=60.) ~xc ~xs domid req =
	(* For both PV and HVM, write the control/shutdown node *)
	let info = Xc.domain_getinfo xc domid in
	if info.Xc.shutdown then (* shutdown domain won't acknowledge *) false else (
		let hvm = (Xc.domain_getinfo xc domid).Xc.hvm_guest in
		shutdown ~xc ~xs ~hvm domid req;
		if not hvm then
		    (* PV domains will acknowledge the request (if not then something
		       very bad is wrong) *)
			shutdown_wait_for_ack ~timeout ~xs domid req
		else
			true
	)

let sysrq ~xs domid key =
	let path = xs.Xs.getdomainpath domid ^ "/control/sysrq" in
	xs.Xs.write path (String.make 1 key)

(** Forcibly shuts down all VBD backends in parallel and returns when they have all
    reported successful flushing.
    extra_debug_paths is a list of xenstore paths which will also be watched
    for manually checking the migrate synchronisation code.
	/!\ This function is actually unused
	FIXME: check if we really need to watch a devices
 *)
let hard_shutdown_all_vbds ~xc ~xs ?(extra_debug_paths = []) (devices: device list) = 
	(* Tell them all to flush now *)
	List.iter (Device.Vbd.hard_shutdown_request ~xs) devices;
	(* If requested we watch additional debugging paths: *)
	let debug_watches = List.map Watch.value_to_appear extra_debug_paths in
	(* Wait for them all to acknowledge *)
	try
		let watches = List.map (Device.Vbd.hard_shutdown_complete ~xs) devices in
		ignore(Watch.wait_for ~xs (Watch.all_of (watches @ debug_watches)));
		debug "VBD backends have flushed"
	with Watch.Timeout _ ->
		debug "Timeout waiting for backends to flush";
		raise Timeout_backend


(* Run an FLR on all passed-in devices *)
let do_flr_on_collection ~xs all_pci_devices =
	(* For each PCI device in the given collection... *)
	List.iter (fun device ->
		debug "Requesting FLR on %s via do_flr_on_collection." (string_of_device device);

		(* Find all PCI device objects matching the given device model. *)
		let devs = Device.PCI.enumerate_devs ~xs device in

		(* And perform an FLR on each of those devices. *)
		List.iter (fun dev -> Device.PCI.do_flr dev) devs

	) all_pci_devices
  
let rec destroy_nowait ?(preserve_xs_vm=false) ~xc ~xs domid ?(do_flr=true) =
	let dom_path = xs.Xs.getdomainpath domid in

	let all_devices = list_devices_for ~xs domid in
	debug "Domain.destroy: all known devices = [ %a ]" (fun () -> String.concat "; ")
          (List.map string_of_device all_devices);

	let all_pci_devices = List.filter (fun device -> device.backend.kind = Pci) all_devices in
	let all_nonpci_devices = List.filter (fun device -> device.backend.kind <> Pci) all_devices in

	(* forcibly shutdown every pci backend. doing it before shutting ioemu ensures that device is back in dom0
         * when surfman gets notified about domain death *)
	List.iter (fun device ->
		try Device.hard_shutdown ~xs device
		with exn -> debug "Caught exception %s while destroying device %s" (Printexc.to_string exn) (string_of_device device);
	) all_pci_devices;

	(* Now we should kill the domain itself *)
	debug "Domain.destroy calling Xc.domain_destroy (domid %d)" domid;
	log_exn_continue "Xc.domain_destroy" (Xc.domain_destroy xc) domid;

	log_exn_continue "Error signaling dm-agents that domain will be destroyed"
	                 (fun () -> Dmagent.stop ~xs domid) ();

	(* destroy stubdom: ask it to die first, then shoot the domain *)
	log_exn_continue "Stubdom destroying failed, no stubdom ?"
		(fun () ->
			let stubdomid = int_of_string (xs.Xs.read (xs.Xs.getdomainpath domid ^ "/image/device-model-domid")) in
			(* ask first *)
			if shutdown_ack ~xc ~xs stubdomid Halt then (
				info "stubdom acknowledged shutdown request. waiting release";
				try
					let with_xal f = let xal = Xal.init () in finally (fun () -> f xal) (fun () -> Xal.close xal) in
					with_xal (fun xal ->
						let reason = Xal.wait_release xal ~timeout:60. stubdomid in
						info "stubdom has died, reason: %s" (Xal.string_of_died_reason reason);
						(* shoot later *)
						destroy_nowait ~xc ~xs stubdomid ~do_flr:false
					)
				with _ ->
					info "stubdom didn't shutdown after 1min";
					raise (Stubdom_didnt_shutdown stubdomid)
			) else (
				debug "stubdom didn't ACK shutdown request";
				(* shoot later *)
				destroy_nowait ~xc ~xs stubdomid ~do_flr:false
			)
		) ();

	log_exn_continue "Error stoping device-model, already dead ?"
	                 (fun () -> Dm.stop ~xs domid Sys.sigterm) ();

	(* forcibly shutdown every non-pci backend *)
	List.iter (fun device ->
		try Device.hard_shutdown ~xs device
		with exn -> debug "Caught exception %s while destroying device %s" (Printexc.to_string exn) (string_of_device device);
	) all_nonpci_devices;

	(* and perform a reset on every PCI backend *)
	if do_flr then do_flr_on_collection ~xs all_pci_devices;

	(* For each device which has a hotplug entry, perform the cleanup. Even if one
	   fails, try to cleanup the rest anyway.*)
	let released = ref [] in
	List.iter (fun x ->
		let exnstr = "waiting for hotplug for " ^ (string_of_device x) in
		log_exn_continue exnstr (fun () ->
			Hotplug.release ~xs x; released := x :: !released
		) ()
	) all_devices;

	(* If we fail to release a device we leak resources. If we are to tolerate this
	   then we need an async cleanup thread. *)
	let failed_devices = List.filter (fun x -> not(List.mem x !released)) all_devices in
	List.iter (fun dev ->
		error "Domain.destroy failed to release device: %s" (string_of_device dev)
	) failed_devices;

	(* Delete the /vm/<uuid> and /vss/<uuid> directories if they exists *)
	if not preserve_xs_vm then (
		begin try xs.Xs.rm (xs.Xs.read (dom_path ^ "/vm")) with _ -> () end;
		begin try xs.Xs.rm (xs.Xs.read (dom_path ^ "/vss")) with _ -> () end;
	);

	(* Delete the /local/domain/<domid> and all the backend device paths *)
	debug "Domain.destroy: rm %s" dom_path;
	xs.Xs.rm dom_path;
	debug "Domain.destroy: deleting backend paths";
	let backend_domids = List.fold_left (fun acc d ->
		let domid = d.backend.domid in
		if List.mem domid acc then acc else domid :: acc) [] all_devices in
	List.iter (fun back_domid ->
		let backend_path = xs.Xs.getdomainpath back_domid ^ "/backend" in
		let all_backend_types = try xs.Xs.directory backend_path with _ -> [] in
		List.iter (fun ty -> log_exn_rm ~xs (Printf.sprintf "%s/%s/%d" backend_path ty domid)) all_backend_types;
	) backend_domids;

	(* If all devices were properly un-hotplugged, then zap the tree in xenstore.
	   If there was some error leave the tree for debugging / async cleanup. *)
	if failed_devices = []
	then log_exn_rm ~xs (Hotplug.get_private_path domid)


let destroy ?(preserve_xs_vm=false) ~xc ~xs domid =
	destroy_nowait ~preserve_xs_vm ~xc ~xs domid ~do_flr:true;
	(* Block waiting for the dying domain to disappear: aim is to catch shutdown errors early*)
	let still_exists () = 
		try
			let info = Xc.domain_getinfo xc domid in
			debug "Domain %d still exists (domid=%d; uuid=%s): waiting for it to disappear."
			      domid info.Xc.domid (Uuid.to_string (Uuid.uuid_of_int_array info.Xc.handle));
			true
		with 
		| Xc.Error err ->
			debug "Xc.domain_getinfo %d threw: %s -- assuming domain nolonger exists" domid err;
			false
		| e ->
			warn "Xc.domain_getinfo %d threw unexpected error: %s -- assuming domain nolonger exists"
			     domid (Printexc.to_string e);
			raise e
		in
	let start = Unix.gettimeofday () in
	let timeout = 30. in
	while still_exists () && (Unix.gettimeofday () -. start < timeout) do
		Unix.sleep 5
	done;
	if still_exists () then (
		(* CA-13801: to avoid confusing people, we shall change this domain's uuid *)
		let s = Printf.sprintf "deadbeef-dead-beef-dead-beef0000%04x" domid in
		warn "Domain stuck in dying state after 30s; resetting UUID to %s" s;
		Xc.domain_sethandle xc domid (Uuid.of_string s);
		raise (Domain_stuck_in_dying_state domid)
	)

type suspend_flag = Live | Debug

(* suspend register the callback function that will be call by linux_save
 * and is in charge to suspend the domain when called. the whole domain
 * context is saved to fd
 *)
let suspend ~xc ~xs ~hvm domid fd flags do_suspend_callback =
	debug "Domain.suspend domid=%d" domid;
	Io.write fd save_signature;

	let cmdline_to_flag flag =
		match flag with
		| Live -> [ Xg.Live ]
		| Debug -> [ Xg.Debug ]
		in
	let flags' = List.concat (List.map cmdline_to_flag flags) in

	let xgh = Xg.init () in
	Xg.domain_save xgh fd domid 0 0 flags' hvm;
	(* FIXME not complete, need to call do_Suspend_callback *)
	Xg.close xgh;

	(* hvm domain need to also save qemu-dm data *)
	if hvm then (
		Io.write fd qemu_save_signature;
		let file = sprintf "/tmp/xen.qemu-dm.%d" domid in
		let file =
			if Sys.file_exists file then
				file
			else
				sprintf "/var/lib/xen/qemu-save.%d" domid
			in
		let fd2 = Unix.openfile file [ Unix.O_RDONLY ] 0o640 in
		let size = (Unix.stat file).Unix.st_size in
		debug "qemu-dm state file size: %d" size;

		finally (fun () ->
			Io.write_int fd size;
			let limit = Int64.of_int size in
			if Unixext.copy_file ~limit fd2 fd <> limit
			then failwith "Failed to write whole qemu-dm state file"
		) (fun () -> 
			Unix.unlink file;
			Unix.close fd2)
	);
	debug "Suspend for domid %d finished" domid


let vcpu_affinity_set ~xc domid vcpu cpumap =
	Xc.vcpu_affinity_set xc domid vcpu cpumap

let vcpu_affinity_get ~xc domid vcpu =
	Xc.vcpu_affinity_get xc domid vcpu

let node_affinity_set ~xc domid nodemap =
	Xc.node_affinity_set xc domid vcpu nodemap

let set_cores_per_socket ~xc domid cores_per_socket =
	Xc.domain_set_cores_per_socket xc domid cores_per_socket

let get_uuid ~xc domid =
	Uuid.uuid_of_int_array (Xc.domain_getinfo xc domid).Xc.handle

let grant_api_access ~xs domid mac ip port session vmref =
	let kvs = [
	        "mac", mac;
		"ip", ip;
		"port", string_of_int port;
		"session_id", session;
		"vm_ref", vmref;
	] in
	xs.Xs.writev (xs.Xs.getdomainpath domid) kvs

let get_api_access ~xs domid =
	let keys = [ "ip"; "port"; "session_id"; "vm_ref" ] in
	let v = xs.Xs.readv (xs.Xs.getdomainpath domid) keys in
	List.nth v 0, int_of_string (List.nth v 1),
	List.nth v 2, List.nth v 3

let guest_get_api_access ~xs =
	let keys = [ "ip"; "port"; "session_id"; "vm_ref" ] in
	let v = xs.Xs.readv "" keys in
	List.nth v 0, int_of_string (List.nth v 1),
	List.nth v 2, List.nth v 3

let add_ioport ~xc domid start_port end_port =
	let nr_ports = end_port - start_port in
	debug "ioport add %d %#x-%#x" domid start_port (start_port + nr_ports);
	Xc.domain_ioport_permission xc domid start_port nr_ports true

let del_ioport ~xc domid start_port end_port =
	let nr_ports = end_port - start_port in
	debug "ioport del %d %#x-%#x" domid start_port (start_port + nr_ports);
	Xc.domain_ioport_permission xc domid start_port nr_ports false

(* start_address and end_address are potentially 64 bit? *)
let add_iomem ~xc domid start_address end_address =
	let mem_to_pfn m = Int64.to_nativeint (Int64.div m 4096L) in
	let start_pfn = mem_to_pfn start_address and end_pfn = mem_to_pfn end_address in
	let nr_pfns = Nativeint.sub end_pfn start_pfn in
	debug "iomem add %d %#nx-%#nx" domid start_pfn end_pfn;
	Xc.domain_iomem_permission xc domid start_pfn nr_pfns true

let del_iomem ~xc domid start_address end_address =
	let mem_to_pfn m = Int64.to_nativeint (Int64.div m 4096L) in
	let start_pfn = mem_to_pfn start_address and end_pfn = mem_to_pfn end_address in
	let nr_pfns = Nativeint.sub end_pfn start_pfn in
	debug "iomem del %d %#nx-%#nx" domid start_pfn end_pfn;
	Xc.domain_iomem_permission xc domid start_pfn nr_pfns false

let add_irq ~xc domid irq =
	debug "irq add %d %#x" domid irq;
	Xc.domain_irq_permission xc domid irq true

let del_irq ~xc domid irq =
	debug "irq del %d %#x" domid irq;
	Xc.domain_irq_permission xc domid irq false

let set_machine_address_size ~xc domid width =
  match width with
    | Some width -> begin
	(debug "set machine address size dom%d to %d bits" domid width);
	Xc.domain_set_machine_address_size xc domid width
	  end
    | None -> ()

let domain_disable_migrate ~xc domid =
  debug "disabling migration for %d" domid ;
  Xc.domain_disable_migrate xc domid

type cpuid_reg = Eax | Ebx | Ecx | Edx
type cpuid_rtype = Clear | Set | Default | Same | Keep

type cpuid_config = ((int64 * int64 option) * ((cpuid_reg * (cpuid_rtype array)) list)) list

exception Cpuid_unknown_type of char
exception Cpuid_unknown_reg of string
exception Cpuid_misconfiguration

let cpuid_reg_of_string = function
	| "eax" -> Eax | "ebx" -> Ebx | "ecx" -> Ecx | "edx" -> Edx
	| s -> raise (Cpuid_unknown_reg s)

let cpuid_rtype_of_char = function
	| '0' -> Clear | '1' -> Set | 'x' -> Default | 's' -> Same | 'k' -> Keep
	| c -> raise (Cpuid_unknown_type c)

let char_of_cpuid_rtype = function
	| Clear -> '0' | Set -> '1' | Default -> 'x' | Same -> 's' | Keep -> 'k'

let cpuid_cfg_to_xc_cpuid_cfg a constr =
	let get_config_for reg lconstr =
		if List.mem_assoc reg lconstr then (
			let rtype = List.assoc reg lconstr in
			if Array.length rtype <> 32 then
				raise Cpuid_misconfiguration;
			let s = String.create 32 in
			Array.iteri (fun i x -> s.[i] <- char_of_cpuid_rtype x) rtype;
			Some s
		) else
			None
		in
	a.(0) <- get_config_for Eax constr;
	a.(1) <- get_config_for Ebx constr;
	a.(2) <- get_config_for Ecx constr;
	a.(3) <- get_config_for Edx constr;
	()

let cpuid_cfg_of_xc_cpuid_cfg cfg =
	let back_to reg arr =
		match arr with
		| None   -> None
		| Some s ->
			let a = Array.create 32 Default in
			for i = 0 to String.length s
			do
				a.(i) <- cpuid_rtype_of_char s.[i]
			done;
			Some (reg, a)
		in
	List.fold_left (fun acc x -> match x with None -> acc | Some x -> x :: acc)
	               [] [ back_to Eax cfg.(0); back_to Ebx cfg.(1);
	                    back_to Ecx cfg.(2); back_to Edx cfg.(3) ]

let cpuid_set ~xc ~hvm domid cfg =
	let tmp = Array.create 4 None in
	let cfgout = List.map (fun (node, constr) ->
		cpuid_cfg_to_xc_cpuid_cfg tmp constr;
		let ret = Xc.domain_cpuid_set xc domid node tmp in
		let ret = cpuid_cfg_of_xc_cpuid_cfg ret in
		(node, ret)
	) cfg in
	cfgout

let cpuid_apply ~xc ~hvm domid =
	Xc.domain_cpuid_apply_policy xc domid

let cpuid_check ~xc cfg =
	List.map (fun (node, constr) ->
		()
		(*
		cpuid_cfg_to_xc_cpuid_cfg tmp constr;
		let (success, cfgout) = Xc.cpuid_check node tmp in
		(success, (node, (cpuid_cfg_of_xc_cpuid_cfg cfgout)))
		*)
	) cfg
