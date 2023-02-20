open Prelude.Ana
open Graph

(* Pure edge type *)
type edge = MyCFG.edge

module VarinfoImpl =
struct
include CilType.Varinfo

(* In order for inner and outter variables to be equal *)
let compare vinfo1 vinfo2 =
  if String.equal vinfo1.vname vinfo2.vname then 0 
  else CilType.Varinfo.compare vinfo1 vinfo2
  
end

module SigmaMap = Map.Make(VarinfoImpl)

(* Value domain for variables contained in sigma mapping.
   The supported types are: Integer and Address of a variable *)
type varDomain = 
  Int of Cilint.cilint * Cilint.cilint * ikind
| Address of varinfo  
| ThreadID of int 
| Error 
(* [@@deriving hash] *) (* Erwartet hash-Funktionen von den Untertypen *)

let middle_intersect_intervals l1 u1 l2 u2 = if u1 = l2 then u1 else if l1 = u2 then l1 else
(  let l_intersect, u_intersect = if u1 > l2 then l2, u1 else l1, u2
in 
let delta = Big_int_Z.abs_big_int (Big_int_Z.sub_big_int u_intersect l_intersect) 
in Big_int_Z.add_big_int l_intersect (Big_int_Z.div_big_int delta (Big_int_Z.big_int_of_int 2))  ) 


let equal_varDomain vd1 vd2 =
  match vd1, vd2 with
  Int(iLower1, iUpper1, ik1), Int(iLower2, iUpper2, ik2) -> (Big_int_Z.eq_big_int iLower1 iLower2) && (Big_int_Z.eq_big_int iUpper1 iUpper2)
  && (CilType.Ikind.equal ik1 ik2)
  | Address(vinfo1), Address(vinfo2) -> CilType.Varinfo.equal vinfo1 vinfo2
  | Error, Error -> true
  | ThreadID(tid1), ThreadID(tid2) -> tid1 = tid2
  | _ -> false

  let show_varDomain vd =
    match vd with Int(iLower, iUpper, ik) -> "Integer of ["^(Big_int_Z.string_of_big_int iLower)^";"^(Big_int_Z.string_of_big_int iUpper)^"] with ikind: "^(CilType.Ikind.show ik)
    | Address(vinfo) -> "Address of "^(CilType.Varinfo.show vinfo)
    | ThreadID(tid) -> "ThreadID of "^(string_of_int tid)
    | Error -> "ERROR"

    (* I need a better hash function for intervals!! *)
let hash_varDomain vd =
  match vd with Int(iLower, iUpper, ik) -> Big_int_Z.int_of_big_int (Big_int_Z.add_big_int iLower iUpper)
  | Address(vinfo) -> CilType.Varinfo.hash vinfo
  | ThreadID(tid) -> tid
  | Error -> 13

(* Pure node type *)
type node = {
  id: int;
  programPoint : MyCFG.node;
  sigma : varDomain SigmaMap.t;
  tid:int;
}

(* Module wrap for node implementing necessary functions for ocamlgraph *)
module NodeImpl =
struct 
type t = node

let show_sigma s = (SigmaMap.fold (fun vinfo vd s -> s^"vinfo="^(CilType.Varinfo.show vinfo)^", ValueDomain="^(show_varDomain vd)^";") s "")


let equal_sigma s1 s2 = 
  if (SigmaMap.is_empty s1) && (SigmaMap.is_empty s2) then true 
  else if (SigmaMap.cardinal s1) != (SigmaMap.cardinal s2) then false
  else
    SigmaMap.fold (fun vinfo varDom b -> b && (if SigmaMap.mem vinfo s2 then equal_varDomain (SigmaMap.find vinfo s2) varDom else false)) s1 true

  let show n = 
    match n with {programPoint=p;sigma=s;id=id;tid=tid} -> "node:{programPoint="^(Node.show p)^"; id="^(string_of_int id)^"; |sigma|="^(string_of_int (SigmaMap.cardinal s))^", sigma=["^(SigmaMap.fold (fun vinfo vd s -> s^"vinfo="^(CilType.Varinfo.show vinfo)^", ValueDomain="^(show_varDomain vd)^";") s "")^"]; tid="^(string_of_int tid)^"}"

let compare n1 n2 = match (n1, n2) with 
({programPoint=p1;sigma=s1;id=id1;tid=tid1},{programPoint=p2;sigma=s2;id=id2;tid=tid2}) -> if (equal_sigma s1 s2)&&(id1 = id2)&&(tid1 = tid2) then Node.compare p1 p2 else -13 

let hash_sigma s = (SigmaMap.fold (fun vinfo vd i -> (CilType.Varinfo.hash vinfo) + (hash_varDomain vd) + i) s 0)

let intersect_sigma sigma1 sigma2 =
  SigmaMap.fold (fun vinfo varDom sigAcc -> if SigmaMap.mem vinfo sigma2 = false then sigAcc else if equal_varDomain varDom (SigmaMap.find vinfo sigma2) then SigmaMap.add vinfo varDom sigAcc else sigAcc) sigma1 SigmaMap.empty

let destruct_add_sigma sigma1 sigma2 = if SigmaMap.is_empty sigma1 then sigma2 else
  SigmaMap.fold (fun vinfo varDom sigAcc -> SigmaMap.add vinfo varDom sigAcc) sigma2 sigma1

let hash {programPoint=n;sigma=s;id=id;tid=tid} = Node.hash n + hash_sigma s + id + tid

  let equal n1 n2 = (compare n1 n2) = 0
end

module EdgePrinter = Printable.SimplePretty(Edge)

(* Module wrap for edge implementing necessary functions for ocamlgraph *)
module EdgeImpl =
struct
type t = edge
let default = Edge.Skip
let show e = EdgePrinter.show e
let compare e1 e2 = Edge.compare e1 e2

  let equal e1 e2 = (compare e1 e2) = 0


end

(* ocamlgraph datastructure *)
module LocTraceGraph = Persistent.Digraph.ConcreteBidirectionalLabeled (NodeImpl) (EdgeImpl)


(* Module wrap for graph datastructure implementing necessary functions for analysis framework *)
module LocalTraces =
struct
include Printable.Std
type t = LocTraceGraph.t

let name () = "traceDataStruc"

let get_all_edges g =
  LocTraceGraph.fold_edges_e (fun x l -> x::l) g []

let get_all_nodes g =
  LocTraceGraph.fold_vertex  (fun x l -> x::l) g []

let show (g:t) =
  "Graph:{{number of edges: "^(string_of_int (LocTraceGraph.nb_edges g))^", number of nodes: "^(string_of_int (LocTraceGraph.nb_vertex g))^","^(LocTraceGraph.fold_edges_e (fun e s -> match e with (v1, ed, v2) -> s^"[node_prev:"^(NodeImpl.show v1)^",label:"^(EdgeImpl.show ed)^",node_dest:"^(NodeImpl.show v2)^"]-----\n") g "" )^"}}\n\n"
  include Printable.SimpleShow (struct
  type nonrec t = t
  let show = show
end)

let show_edge e =
  match e with (v1, ed, v2) -> "[node_prev:"^(NodeImpl.show v1)^",label:"^(EdgeImpl.show ed)^",node_dest:"^(NodeImpl.show v2)^"]"

  (* Im gonna implement this manually.  *)
  let rec equal_helper2 (node_prev1, edge1, node_dest1) edgeList =
    match edgeList with (node_prev2, edge2, node_dest2)::xs -> 
      ((NodeImpl.equal node_prev1 node_prev2)&&(EdgeImpl.equal edge1 edge2)&&(NodeImpl.equal node_dest1 node_dest2)) || (equal_helper2 (node_prev1, edge1, node_dest1) xs )
      | [] -> false

let equal_edge (prev_node1, edge1, dest_node1) (prev_node2, edge2, dest_node2) = (NodeImpl.equal prev_node1 prev_node2)&&(EdgeImpl.equal edge1 edge2)&&(NodeImpl.equal dest_node1 dest_node2)

let rec equal_helper1 edgeList1 edgeList2 =
  match edgeList1 with x::xs -> (equal_helper2 x edgeList2)&&(equal_helper1 xs edgeList2)
  | [] -> true
let equal g1 g2 = print_string "\nGraph.equal BEGIN\n";
if (LocTraceGraph.nb_edges g1 != LocTraceGraph.nb_edges g2) || (LocTraceGraph.nb_vertex g1 != LocTraceGraph.nb_vertex g2) then (print_string "g1 and g2 are NOT the same, they have different length\nGraph.equal END\n";false) else (
(* print_string ("g1-edges="^(LocTraceGraph.fold_edges_e (fun ed s -> (show_edge ed)^",\n"^s) g1 "")^"\n");
print_string ("g2-edges="^(LocTraceGraph.fold_edges_e (fun ed s -> (show_edge ed)^",\n"^s) g2 "")^"\n"); *)
let edgeList1 = get_all_edges g1
in let edgeList2 = get_all_edges g2
in
(* print_string ("equal_helper1 wird jetzt aufgerufen mit\nedgeList1="^(List.fold (fun s elem -> s^", "^(show_edge elem)) "" edgeList1)^"\nedgeList2="^(List.fold (fun s elem -> s^", "^(show_edge elem)) "" edgeList2)^"\n"); *)
  let tmp = equal_helper1 (edgeList1) (edgeList2)
  in if tmp = false then print_string "g1 and g2 are NOT the same with even length\n" else print_string "g1 and g2 are the same with even length\n"; print_string "\nGraph.equal END\n";tmp)

    (* eventuell liegt hier der Fehler?*)
let hash g1 =
  let tmp = (List.fold (fun i node -> (NodeImpl.hash node)+i) 0 (get_all_nodes g1))
in
  (LocTraceGraph.nb_edges g1) + (LocTraceGraph.nb_vertex g1) + tmp

(* needs to be a total order! *)
  let compare g1 g2 =   print_string "\nGraph.compare BEGIN\n";
  if equal g1 g2 then (
    (* print_string ("The two graphs are equal in compare: g1="^(show g1)^" with hash="^(string_of_int (hash g1))^"\n and g2="^(show g2)^" with hash="^(string_of_int (hash g2))^" \n\nGraph.compare END\n"); *)
   print_string("Graph.compare END\n"); 0) else
      (
        (* print_string ("Graphs are not equal in compare with g1="^(show g1)^" with hash="^(string_of_int (hash g1))^"\n and g2="^(show g2)^" with hash="^(string_of_int (hash g2))^"\n\nGraph.compare END\n"); *)
      (* relying on the polymorphic equal here is a bit of a stop-gap, one should do this properly by using the compares of the edges and nodes*)
      print_string("Graph.compare END\n"); compare g1 g2)

(* Dummy to_yojson function *)
let to_yojson g1 :Yojson.Safe.t = `Variant("bam", None)

(* Retrieves a list of sigma mappings in a graph of a given node *)
let get_sigma g (progPoint:MyCFG.node) = 
  if Node.equal progPoint MyCFG.dummy_node then [SigmaMap.empty] else(
  if LocTraceGraph.is_empty g then
  (match progPoint with 
  | FunctionEntry({svar={vname=s;_}; _})-> if String.equal s "@dummy" then (print_string "Hey, I found a dummy node on a yet empty graph\n";[SigmaMap.empty]) else [] 
    | _ -> [])
  else  
  (let tmp =
LocTraceGraph.fold_vertex (fun {programPoint=p1;sigma=s1;_} l -> 
  if Node.equal p1 progPoint then s1::l else l) g []
  in 
  if List.is_empty tmp then [] else tmp))

  let get_nodes programPoint sigma graph =
let all_nodes = get_all_nodes graph
  in 
  let tmp = List.fold (fun acc {programPoint=p1;sigma=s1;id=i1;tid=tid1} -> if (Node.equal programPoint p1)&&(NodeImpl.equal_sigma sigma s1) then ({programPoint=p1;sigma=s1;id=i1;tid=tid1})::acc else acc ) [] all_nodes 
in
if Node.equal programPoint MyCFG.dummy_node then (* then I want to have the 'latest' dummy node *)
  [(List.fold (fun {id=id_acc;programPoint=progP_acc;sigma=s_acc;tid=tid_acc} {id=id_fold;programPoint=progP_fold;sigma=s_fold;tid=tid_fold} -> if id_acc > id_fold then {id=id_acc;programPoint=progP_acc;sigma=s_acc;tid=tid_acc} else {id=id_fold;programPoint=progP_fold;sigma=s_fold;tid=tid_fold} ) {programPoint=programPoint;sigma=sigma;id=(-1);tid=(-1)} tmp)] else tmp

let check_for_duplicates g =
  let edgeList = get_all_edges g
in 
let rec check_helper1 (prev_node, edge, dest_node) innerList =
  match innerList with (prev_inner, edge_inner, dest_inner)::xs -> 
    if (NodeImpl.equal prev_node prev_inner)&&(Edge.equal edge edge_inner)&&(NodeImpl.equal dest_node dest_inner) then true else check_helper1 (prev_node, edge, dest_node) xs
    | [] -> false
  in let rec check_helper2 outerList =
    match outerList with x::xs -> if check_helper1 x xs then true else check_helper2 xs
      | [] -> false
  in check_helper2 edgeList
    

(* Applies an gEdge to graph 
   Explicit function for future improvements *)
let extend_by_gEdge gr gEdge = print_string "LocalTraces.extend_by_gEdge was invoked\n";
  if (List.fold (fun acc edge_fold -> (equal_edge edge_fold gEdge)||acc) false (get_all_edges gr)) 
    then (print_string ("but gEdge="^(show_edge gEdge)^" is already contained in:\n"^(show gr)^"\n");gr) 
else (let tmp = LocTraceGraph.add_edge_e gr gEdge in print_string ("extend_by_gEdge succeeded with new graph:\n"^(show tmp)^"\n"); tmp) 

  let error_node : MyCFG.node = 
    FunctionEntry({svar=makeVarinfo false "__goblint__traces__error" (TInt(IInt,[])); 
                   sformals=[];
                   slocals=[];
                   smaxid=0;
                   sbody={battrs=[];bstmts=[]};
                   smaxstmtid=None;
                   sallstmts=[]})

  let return_vinfo = makeVarinfo false "__goblint__traces__return" (TInt(IInt,[]))

  let branch_vinfo = makeVarinfo false "__goblint__traces__branch" (TInt(IInt,[]))

    let get_predecessors_edges graph node = 
      List.fold 
      (fun list edge -> match edge with (prev_node, edgeLabel, dest_node) -> if NodeImpl.equal node dest_node then edge::list else list)
       [] (get_all_edges graph)

    let get_predecessors_nodes graph node =
        List.fold 
        (fun list edge -> match edge with (prev_node, edgeLabel, dest_node) -> if NodeImpl.equal node dest_node then prev_node::list else list)
         [] (get_all_edges graph)

    let get_successors_edges graph node =
      List.fold 
      (fun list edge -> match edge with (prev_node, edgeLabel, dest_node) -> if NodeImpl.equal node prev_node then edge::list else list)
       [] (get_all_edges graph)

    let find_globvar_assign_node global graph node = print_string ("find_globvar_assign_node global wurde aufgerufen\n");
    let workQueue = Queue.create ()
  in Queue.add node workQueue;
  let rec loop visited = (print_string ("\nloop wurde aufgerufen mit |workQueue| = "^(string_of_int (Queue.length workQueue))^" und peek: "^(NodeImpl.show (Queue.peek workQueue))^" und visited: "^(List.fold (fun s n -> ((NodeImpl.show n)^", "^s)) "" visited)^" and |visited| = "^(string_of_int (List.length visited))^"\n");
    let q = Queue.pop workQueue
in let predecessors = print_string ("\nin loop we get the predessecors in graph:"^(show graph)^"\n");get_predecessors_edges graph q
in let tmp_result = print_string ("the predecessors are: "^(List.fold (fun s ed -> s^", "^(show_edge ed)) "" predecessors)^"\n");
List.fold (fun optionAcc (prev_node, (edge:MyCFG.edge), _) -> 
match edge with 
    | (Assign((Var(edgevinfo),_), edgeExp)) -> if CilType.Varinfo.equal global edgevinfo then (print_string ("Assignment mit global wurde gefunden! global="^(CilType.Varinfo.show global)^", edgevinfo="^(CilType.Varinfo.show edgevinfo)^"\n");Some(prev_node,edge)) else optionAcc
    | _ -> optionAcc
  ) None predecessors
in
let skip_edge:edge = Skip (* This is needed otherwise it errors with unbound constructor *)
in
match tmp_result with
| None -> List.iter (fun pred -> if List.mem pred visited then () else Queue.add pred workQueue) (get_predecessors_nodes graph q);
  if Queue.is_empty workQueue then ({programPoint=error_node;sigma=SigmaMap.empty;id= -1;tid= -1}, skip_edge) else (print_string ("we recursively call loop again while working on node "^(NodeImpl.show q)^"\n");loop (q::visited))
| Some(nodeGlobalAssignment) -> nodeGlobalAssignment
  )
in loop []

    let get_succeeding_node prev_node edge_label graph =
  print_string ("LocalTraces.get_succeeding_node was invoked with prev_node="^(NodeImpl.show prev_node)^", edge_label="^(EdgeImpl.show edge_label)^" and\n"^(show graph)^"\n");
  let edgeList = get_all_edges graph
in let tmp =
List.fold (fun acc_node ((prev_fold:node), edge_fold, (dest_fold:node)) -> 
  if (NodeImpl.equal prev_node prev_fold)&&(Edge.equal edge_label edge_fold) 
    then dest_fold
    else acc_node
      ) {programPoint=error_node;sigma=SigmaMap.empty;id=(-1);tid= -1} edgeList
  in print_string ("in LocalTraces.get_succeeding_node we found the node "^(NodeImpl.show tmp)^"\n"); tmp

(* finds the return endpoints of a calling node *)
    let find_returning_node prev_node edge_label graph =
  let node_start = get_succeeding_node prev_node edge_label graph
in
let rec find_returning_node_helper current_node current_saldo =(
  print_string("find_returning_node_helper has been invoked with current_node="^(NodeImpl.show current_node)^", current_saldo="^(string_of_int current_saldo)^"\n");
  let succeeding_edges = get_successors_edges graph current_node
in
List.fold (fun acc_node ((prev_fold:node), (edge_fold:Edge.t), (dest_fold:node)) -> 
  match edge_fold with Proc(_) -> find_returning_node_helper dest_fold (current_saldo +1)
    | Ret(_) -> if current_saldo = 1 then dest_fold else find_returning_node_helper dest_fold (current_saldo - 1)
    | _ -> find_returning_node_helper dest_fold current_saldo
  ) {programPoint=error_node;sigma=SigmaMap.empty;id=(-1);tid= -1} succeeding_edges
  )
in find_returning_node_helper node_start 1

(* Interface for possible improvement: integrate last-component to LocalTraces-datastructure *)
(* Searches for last node in a trace. It has to contain the programPoint, otherwise an error-node is returned *)
    let get_last_node_progPoint graph programPoint =
      let allNodes = get_all_nodes graph
    in 
    let rec loop nodeList =
      match nodeList with 
        | x::xs -> if (List.is_empty (get_successors_edges graph x))&&(Node.equal x.programPoint programPoint) then x else loop xs
        | [] -> {programPoint=error_node;sigma=SigmaMap.empty; tid= -1; id= -1}
    in loop allNodes

    let get_last_node graph =
      let allNodes = get_all_nodes graph
    in 
    let rec loop nodeList =
      match nodeList with 
        | x::xs -> if (List.is_empty (get_successors_edges graph x)) then x else loop xs
        | [] -> {programPoint=error_node;sigma=SigmaMap.empty; tid= -1; id= -1}
    in loop allNodes

    let get_all_nodes_progPoint graph programPoint=
    let allNodes = get_all_nodes graph
  in 
  let rec loop nodeList acc =
    match nodeList with 
      | x::xs -> if (Node.equal x.programPoint programPoint) then loop xs (x::acc) else loop xs acc
      | [] -> acc
  in loop allNodes []
  
(* Interface for future efficient implementation *)
let find_calling_node return_node graph progPoint =
  let allNodes = get_all_nodes_progPoint graph progPoint
in
let rec inner_loop node_candidate edgeList =
  match edgeList with (_,e,_)::es -> 
  if NodeImpl.equal return_node (find_returning_node node_candidate e graph) then node_candidate
  else inner_loop node_candidate es
  | [] -> {programPoint=error_node;sigma= SigmaMap.empty;id= -1; tid= -1}
in
let rec loop nodeList =
  match nodeList with
  | x::xs -> (
    let succeedingEdgesList = get_successors_edges graph x
in
    let tmp_result = inner_loop x succeedingEdgesList
in 
if Node.equal tmp_result.programPoint error_node then loop xs else tmp_result
  )
    | [] -> {programPoint=error_node;sigma= SigmaMap.empty;id= -1; tid= -1}
    in loop allNodes

    (* In this function I assume, that traces do not contain circles *)
let find_creating_node last_node graph creatorTID =
  print_string ("find_creating_node was invoked with last_node="^(NodeImpl.show last_node)^",\ngraph="^(show graph)^"\n");
  let lastNodeTid = last_node.tid
in
let workQueue = Queue.create ()
  in Queue.add last_node workQueue;
  
  let rec loop () =
    let current_node = Queue.pop workQueue
  in
  let rec inner_loop edges =
    match edges with
    (precedingNode, (edgeLabel:edge),_)::xs ->
      (match edgeLabel with (Proc(_, Lval(Var(v),_), _)) -> (
        if (precedingNode.tid = creatorTID)&&(current_node.tid = lastNodeTid) then Some(precedingNode)
      else inner_loop xs)
        | _ ->  inner_loop xs )
      | [] -> None
  in
    let precedingEdges = get_predecessors_edges graph current_node
  in
  match inner_loop precedingEdges with
  None -> List.iter (fun node -> Queue.add node workQueue ) (get_predecessors_nodes graph current_node);
  loop ()
  | Some(found_node) -> found_node
in loop ()

let exists_node graph node =
let all_nodes = get_all_nodes graph
in
List.exists (fun node_exists -> NodeImpl.equal node node_exists) all_nodes

  let equal_edge_lists edgeList1 edgeList2 =
    if List.length edgeList1 != List.length edgeList2 then false else
      (
        let rec loop list =
          match list with x::xs ->  if List.exists (fun edge -> equal_edge edge x) edgeList2 then loop xs else false
            | [] -> true
        in
        loop edgeList1
      )
  let merge_graphs graph1 graph2 =
    List.fold (fun graph_fold edge_fold -> extend_by_gEdge graph_fold edge_fold) graph2 (get_all_edges graph1)

  let exists_TID tid graph =
    let allNodes = get_all_nodes graph
  in
  let rec loop nodeList =
    match nodeList with node::xs -> if node.tid = tid then true else loop xs
      | [] -> false
    in loop allNodes  
  end

(* Set domain for analysis framework *)
module GraphSet = struct
include SetDomain.Make(LocalTraces)
end

let graphSet_to_list graphSet =
  GraphSet.fold (fun g acc -> g::acc) graphSet []

(* ID Generator *)
class id_generator = 
object(self)
 val mutable currentID = 0
 val mutable edges:((node * edge * node) list) = []
 method increment () =
  currentID <- currentID + 1; 
  currentID

  (* TODO: TID vom destination node muss auch geprüft werden mit tid_find*)
  method getID (prev_node:node) (edge:MyCFG.edge) (dest_programPoint:MyCFG.node) (dest_sigma:varDomain SigmaMap.t) (dest_tid:int) =
    print_string "getID wurde aufgerufen\n";
    let id = List.fold (fun acc (prev_node_find, edge_find, {programPoint=p_find;sigma=s_find;id=id_find;tid=tid_find}) -> 
     if (NodeImpl.equal prev_node prev_node_find)&&(Edge.equal edge edge_find)&&(Node.equal dest_programPoint p_find)&&(NodeImpl.equal_sigma dest_sigma s_find)&&(tid_find = dest_tid) then id_find else acc) (-1) edges 
  in 
  if id = (-1) then ( print_string ("No existing edge for this combination was found, so we create a new ID\n
    for prev_node="^(NodeImpl.show prev_node)^", edge="^(EdgeImpl.show edge)^", dest_progPoint="^(Node.show dest_programPoint)^", dest_sigma="^(NodeImpl.show_sigma dest_sigma)^"\n
in edges={"^(List.fold (fun acc_fold edge_fold -> acc_fold^(LocalTraces.show_edge edge_fold)^"\n") "" edges)^"}\n");
  (* TID should not matter here --- but it does! *)
  edges <- (prev_node, edge, {programPoint=dest_programPoint;sigma=dest_sigma;id=currentID+1;tid=dest_tid})::edges; 
  self#increment ()) else (print_string ("id was found: "^(string_of_int id)^"\n"); id)
end

let idGenerator = new id_generator

class random_int_generator =
object(self)
  val mutable traceVarList:((int * varinfo * int) list) = []

  method getRandomValue (hash:int) (var:varinfo) = 
    if List.is_empty traceVarList then Random.init 100;
    print_string ("random_int_generator#getRandomValue was invoked with hash="^(string_of_int hash)^", var="^(CilType.Varinfo.show var)^";
    \nwith current traceVarList="^(List.fold (fun acc (int_fold, vinfo_fold, value_fold) -> acc^"; ("^(string_of_int int_fold)^","^(CilType.Varinfo.show vinfo_fold)^","^(string_of_int value_fold)^")") "" traceVarList)^"\n");
    if List.exists ( fun (int_list, vinfo_list,_) -> (int_list = hash)&&(CilType.Varinfo.equal var vinfo_list) ) traceVarList 
      then (print_string "random value exists already\n";
        let _,_,randomValue =List.find (fun (int_list, vinfo_list,_) -> (int_list = hash)&&(CilType.Varinfo.equal var vinfo_list)) traceVarList
in randomValue) 
  else
    ( print_string "new random value is generated\n";
      let randomValue = (Random.int 10) - (Random.int 10)
  in
  traceVarList <- (hash, var, randomValue)::traceVarList;
  randomValue)

end

let randomIntGenerator = new random_int_generator

module ThreadIDLocTrace = struct
  type t = int
  let is_write_only _ = false

  let equal (tid1:t) (tid2:t) = tid1 = tid2

  let hash tid = tid

  let compare tid1 tid2 = tid1 - tid2

  let show tid = string_of_int tid

  include Printable.SimpleShow (struct
      type nonrec t = t
      let show = show
    end)

    let name () = "threadID"

    let tag tid = failwith ("tag")

    let arbitrary tid = failwith ("no arbitrary")

    let relift tid = failwith ("no relift")
end