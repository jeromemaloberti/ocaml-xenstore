(*
 * Copyright (C) Citrix Systems Inc.
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
let debug fmt = Logging.debug "store" fmt
let error fmt = Logging.debug "error" fmt

open Junk

exception Already_exists of string

module Node = struct

type t = {
	name: Symbol.t;
	creator: int;
	perms: Xs_protocol.ACL.t;
	value: string;
	children: t list;
}

let create _name _creator _perms _value =
	{ name = Symbol.of_string _name; creator = _creator; perms = _perms; value = _value; children = []; }

let get_creator node = node.creator

let set_value node nvalue = 
	if node.value = nvalue
	then node
	else { node with value = nvalue }

let set_perms node nperms = { node with perms = nperms }
let get_perms node = node.perms

let add_child node child =
	{ node with children = child :: node.children }

let exists node childname =
	let childname = Symbol.of_string childname in
	List.exists (fun n -> n.name = childname) node.children

let find node childname =
	let childname = Symbol.of_string childname in
	List.find (fun n -> n.name = childname) node.children

let replace_child node child nchild =
	(* this is the on-steroid version of the filter one-replace one *)
	let rec replace_one_in_list l =
		match l with
		| []                               -> []
		| h :: tl when h.name = child.name -> nchild :: tl
		| h :: tl                          -> h :: replace_one_in_list tl
		in
	{ node with children = (replace_one_in_list node.children) }

let del_childname node childname =
	let sym = Symbol.of_string childname in
	let rec delete_one_in_list l =
		match l with
		| []                        -> raise Not_found
		| h :: tl when h.name = sym -> tl
		| h :: tl                   -> h :: delete_one_in_list tl
		in
	{ node with children = (delete_one_in_list node.children) }

let del_all_children node =
	{ node with children = [] }

let rec recurse fct node = fct node; List.iter (recurse fct) node.children

let unpack node = (Symbol.to_string node.name, node.perms, node.value)

end

let char_is_valid c =
	(c >= 'a' && c <= 'z') ||
	(c >= 'A' && c <= 'Z') ||
	(c >= '0' && c <= '9') ||
	c = '_' || c = '-' || c = '@'

let name_is_valid name =
	name <> "" && String.fold_left (fun accu c -> accu && char_is_valid c) true name

let is_valid = List.for_all name_is_valid

type path = string list

let path_of_string = function
	| "/" -> []
	| path ->
		if String.length path > 1024
		then invalid_arg "paths larger than 1024 bytes are invalid";
		begin match String.split '/' path with
		| "" :: path ->
			if not(is_valid path)
			then invalid_arg "valid paths contain only ([a-z]|[A-Z]|[0-9]|-|_|@])+";
			path
		| path ->
			invalid_arg "valid paths have a /-prefix"
		end

let path_to_string path = String.concat "/" ("" :: path)

module Name = struct

	type t =
		| IntroduceDomain
		| ReleaseDomain
		| Absolute of path
		| Relative of path

	let is_relative = function
		| Relative _ -> true
		| _ -> false

	let make_absolute t path = match t with
		| Relative p -> Absolute (path_of_string path @ p)
		| x -> x

	let introduceDomain = IntroduceDomain
	let releaseDomain = ReleaseDomain

	let of_string = function
        | "@introduceDomain" -> IntroduceDomain
        | "@releaseDomain"   -> ReleaseDomain
        | "" ->
                invalid_arg "zero-length paths are invalid";
		| path when path.[0] <> '/' ->
			if String.length path > 1024
			then invalid_arg "paths larger than 1024 bytes are invalid";
			let path = String.split '/' path in
            if not(is_valid path)
			then invalid_arg "valid paths contain only ([a-z]|[A-Z]|[0-9]|-|_|@])+";
            Relative path
		| path -> Absolute (path_of_string path)

	let to_string = function
		| IntroduceDomain -> "@introduceDomain"
		| ReleaseDomain -> "@releaseDomain"
		| Absolute path -> path_to_string path
		| Relative path -> String.concat "/" path

	let to_key = function
		| IntroduceDomain -> [ "@introduceDomain" ]
		| ReleaseDomain -> [ "@releaseDomain" ]
		| Absolute p -> "" :: p
		| Relative p -> "" :: p

end

module Path = struct

type t = string list

exception Doesnt_exist of string

let getdomainpath domid = [ "local"; "domain"; Printf.sprintf "%u" domid ]

let create path connection_path =
	let open Name in
	match of_string path with
	| Absolute path -> path
	| Relative x -> connection_path @ x
	| _ -> invalid_arg (Printf.sprintf "invalid path: %s" path)

let to_name x = Name.Absolute x

let of_string = path_of_string
let to_string = path_to_string
let to_string_list x = x
let of_string_list x = x

let doesnt_exist t = raise (Doesnt_exist (to_string t))

let get_parent t : t = match t with
	| [] -> t
	| t -> List.rev (List.tl (List.rev t))

let make_relative base t =
	let open Name in
	match t with
	| IntroduceDomain
	| ReleaseDomain
	| Relative _ -> t
	| Absolute t ->
		(* base should be a prefix of t *)
		let rec f x y = match x, y with
			| x :: xs, y :: ys when x = y -> f xs ys
			| [], y -> Relative y
			| _, _ -> Absolute t in
		f base t

let list_tl_multi n l =
	let rec do_tl i x =
		if i = 0 then x else do_tl (i - 1) (List.tl x)
		in
	do_tl n l

(* string utils *)
let get_hierarchy path =
	let l = List.length path in
	let revpath = List.rev path in
	let rec sub i =
		let x = List.rev (list_tl_multi (l - i) revpath) in
		if i = l then [ x ] else x :: sub (i + 1)
	in
	sub 0

let get_common_prefix p1 p2 =
	let rec compare l1 l2 =
		match l1, l2 with
		| h1 :: tl1, h2 :: tl2 ->
			if h1 = h2 then h1 :: (compare tl1 tl2) else []
		| _, [] | [], _ ->
				(* if l1 or l2 is empty, we found the equal part already *)
			[]
	in
	compare p1 p2

let rec lookup_modify node path fct =
	match path with
	| []      -> raise Not_found
	| h :: [] -> fct node h
	| h :: l  ->
		let (n, c) =
			if not (Node.exists node h) then
				raise (Doesnt_exist h)
			else
				(node, Node.find node h) in
		let nc = lookup_modify c l fct in
		Node.replace_child n c nc

let apply_modify rnode path fct =
	lookup_modify rnode path fct

let set_node rnode path nnode =
	let quota = Quota.create () in
	Node.recurse (fun node -> Quota.incr quota (Node.get_creator node)) nnode;
	if path = [] then
		nnode, quota
	else
		let set_node node name =
			try
				let ent = Node.find node name in
				Node.recurse (fun node -> Quota.decr quota (Node.get_creator node)) ent;
				Node.replace_child node ent nnode
			with Not_found ->
				Node.add_child node nnode
			in
		apply_modify rnode path set_node, quota

(* read | ls | getperms use this *)
let rec lookup node path fct =
	match path with
	| []      -> raise Not_found
	| h :: [] -> fct node h
	| h :: l  -> let cnode = Node.find node h in lookup cnode l fct

let apply rnode path fct =
	lookup rnode path fct
end

type t =
{
	mutable stat_transaction_coalesce: int;
	mutable stat_transaction_abort: int;
	mutable root: Node.t;
	mutable quota: Quota.t;
}

let get_root store = store.root
let set_root store root =
	debug "Updating root of store";
	store.root <- root

let get_quota store = store.quota
let set_quota store quota = store.quota <- quota

(* modifying functions *)
let path_mkdir store creator perm path =
	let do_mkdir node name =
		try
			let ent = Node.find node name in
			Perms.check perm Perms.WRITE ent.Node.perms;
			raise (Already_exists (Path.to_string path))
		with Not_found ->
			Perms.check perm Perms.WRITE node.Node.perms;
			Node.add_child node (Node.create name creator node.Node.perms "") in
	if path = [] then
		store.root
	else
		Path.apply_modify store.root path do_mkdir

let path_write store creator perm path value =
	let node_created = ref false in
	let do_write node name =
		try
			let ent = Node.find node name in
			Perms.check perm Perms.WRITE ent.Node.perms;
			let nent = Node.set_value ent value in
			Node.replace_child node ent nent
		with Not_found ->
			node_created := true;
			Perms.check perm Perms.WRITE node.Node.perms;
			Node.add_child node (Node.create name creator node.Node.perms value) in
	if path = [] then (
		Perms.check perm Perms.WRITE store.root.Node.perms;
		Node.set_value store.root value, false
	) else
		Path.apply_modify store.root path do_write, !node_created

let path_rm store perm path =
	let do_rm node name =
		try
			let ent = Node.find node name in
			Perms.check perm Perms.WRITE ent.Node.perms;
			Node.del_childname node name
		with Not_found -> Path.doesnt_exist path in
	if path = [] then
		Node.del_all_children store.root
	else
		Path.apply_modify store.root path do_rm

let path_setperms store perm path perms =
	if path = [] then
		Node.set_perms store.root perms
	else
		let do_setperms node name =
			let c = Node.find node name in
			Perms.check perm Perms.CHANGE_ACL c.Node.perms;
			Perms.check perm Perms.WRITE c.Node.perms;
			let nc = Node.set_perms c perms in
			Node.replace_child node c nc
		in
		Path.apply_modify store.root path do_setperms

(* accessing functions *)
let lookup node path =
	let rec lookup_get node path =
		match path with
		| []      -> raise Not_found
		| h :: [] ->
			(try
				 Node.find node h
			 with Not_found -> Path.doesnt_exist path)
		| h :: l  -> let cnode = Node.find node h in lookup_get cnode l in

	if path = [] then
		Some node
	else (
		try Some (lookup_get node path) with Path.Doesnt_exist _ -> None
	)

let read store perm path =
	try
		let do_read node name =
			let ent = Node.find node name in
			Perms.check perm Perms.READ ent.Node.perms;
			ent.Node.value
		in
		if path = [] then (
			let ent = store.root in
			Perms.check perm Perms.READ ent.Node.perms;
			ent.Node.value
		) else
			Path.apply store.root path do_read
	with
		| Not_found -> Path.doesnt_exist path

let ls store perm path =
	try
		let children =
			if path = [] then
				store.root.Node.children
			else
				let do_ls node name =
					let cnode =
						try Node.find node name
						with Not_found ->
							Path.doesnt_exist path
					in
					Perms.check perm Perms.READ cnode.Node.perms;
					cnode.Node.children in
				Path.apply store.root path do_ls in
		List.rev (List.map (fun n -> Symbol.to_string n.Node.name) children)
	with
		| Not_found -> Path.doesnt_exist path

let getperms store perm path =
	try
		if path = [] then
			store.root.Node.perms
		else
			let fct n name =
				let c = Node.find n name in
				Perms.check perm Perms.READ c.Node.perms;
				c.Node.perms in
			Path.apply store.root path fct
	with
		| Not_found -> Path.doesnt_exist path

let exists store path =
	if path = [] then
		true
	else
		try
			let check_exist node name =
				ignore(Node.find node name);
				true in
			Path.apply store.root path check_exist
		with Not_found -> false

(* others utils *)
let traversal root_node f =
	let rec _traversal path node =
		f path node;
		List.iter (_traversal (path @ [ Symbol.to_string node.Node.name ])) node.Node.children
		in
	_traversal [] root_node
		
let dump_store_buf root_node =
	let buf = Buffer.create 8192 in
	let dump_node path node =
		let pathstr = String.concat "/" path in
		Printf.bprintf buf "%s/%s{%s}" pathstr (Symbol.to_string node.Node.name)
		               (String.escaped (Xs_protocol.ACL.to_string node.Node.perms));
		if String.length node.Node.value > 0 then
			Printf.bprintf buf " = %s\n" (String.escaped node.Node.value)
		else
			Printf.bprintf buf "\n";
		in
	traversal root_node dump_node;
	buf

let dump_store chan root_node =
	let buf = dump_store_buf root_node in
	output_string chan (Buffer.contents buf);
	Buffer.reset buf

let dump_fct store f = traversal store.root f
let dump store out_chan = dump_store out_chan store.root
let dump_stdout store = dump_store stdout store.root
let dump_buffer store = dump_store_buf store.root


(* modifying functions with quota udpate *)
let set_node store path node =
	let root, quota_diff = Path.set_node store.root path node in
	store.root <- root;
	Quota.union store.quota quota_diff

let write store creator perm path value =
	Quota.check store.quota creator (String.length value);
	let root, node_created = path_write store creator perm path value in
	if node_created
	then Quota.incr store.quota creator;
	store.root <- root


let mkdir store creator perm path =
	try
		let root = path_mkdir store creator perm path in
		Quota.incr store.quota creator;
		store.root <- root
	with Already_exists _ -> ()

let rm store perm path =
	(* If the parent node doesn't exist then fail *)
	let parent = Path.get_parent path in
	if not(exists store parent) then Path.doesnt_exist parent;
	try
		let rmed_node = lookup store.root path in
		match rmed_node with
			| None -> ()
			| Some node when node = store.root ->
				invalid_arg "removing the root node is forbidden"
			| Some rmed_node ->
				store.root <- path_rm store perm path;
				Node.recurse (fun node -> Quota.decr store.quota (Node.get_creator node)) rmed_node
	with
		| Not_found -> Path.doesnt_exist path		

let setperms store perm path nperms =
	try
		match lookup store.root path with
			| None -> Path.doesnt_exist path
			| Some node ->
				store.root <- path_setperms store perm path nperms
	with
		| Not_found -> Path.doesnt_exist path

let create () = {
	stat_transaction_coalesce = 0;
	stat_transaction_abort = 0;
	root = Node.create "" 0 (Xs_protocol.ACL.({ owner = 0; other = NONE; acl = [] })) "";
	quota = Quota.create ();
}
let copy store = {
	stat_transaction_coalesce = store.stat_transaction_coalesce;
	stat_transaction_abort = store.stat_transaction_abort;
	root = store.root;
	quota = Quota.copy store.quota;
}

let mark_symbols store =
	Node.recurse (fun node -> Symbol.mark_as_used node.Node.name) store.root

let incr_transaction_coalesce store =
	store.stat_transaction_coalesce <- store.stat_transaction_coalesce + 1
let incr_transaction_abort store =
	store.stat_transaction_abort <- store.stat_transaction_abort + 1

let stats store =
	let nb_nodes = ref 0 in
	traversal store.root (fun path node ->
		incr nb_nodes
	);
	!nb_nodes, store.stat_transaction_abort, store.stat_transaction_coalesce
