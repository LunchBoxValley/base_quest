extends Node  # Autoload name: GameManager

# ---------- Config (only used if GameDirector doesn’t inject) ----------
const RUNNER_SCENE_PATH := "res://entities/runner/Runner.tscn"  # update if different
const RUNNERS_PARENT_NAME := "Runners"

const HOME_CANDIDATES := ["HomePlate", "Home", "Plate"]

const BASE1_CANDIDATES := ["Base1", "FirstBase", "First", "Base 1", "Base_1"]
const BASE2_CANDIDATES := ["Base2", "SecondBase", "Second", "Base 2", "Base_2"]
const BASE3_CANDIDATES := ["Base3", "ThirdBase", "Third", "Base 3", "Base_3"]

# extra prefixes we’ll try when resolving by name
const NAME_PREFIXES := ["", "Entities/", "Entities/Bases/"]

# ---------- Optional runtime overrides (set from GameDirector) ----------
var _runner_scene_override: PackedScene = null
var _runners_parent_path_override: NodePath = NodePath()
var _home_path_override: NodePath = NodePath()
var _b1_path_override: NodePath = NodePath()
var _b2_path_override: NodePath = NodePath()
var _b3_path_override: NodePath = NodePath()

func set_runner_scene(p: PackedScene) -> void:
	_runner_scene_override = p

func set_runners_parent_path(np: NodePath) -> void:
	_runners_parent_path_override = np

func set_base_paths(home_np: NodePath, b1_np: NodePath, b2_np: NodePath, b3_np: NodePath) -> void:
	_home_path_override = home_np
	_b1_path_override = b1_np
	_b2_path_override = b2_np
	_b3_path_override = b3_np

# Call this after setting overrides (GameDirector does this)
func refresh_scene_refs() -> void:
	_resolve_nodes()

# ---------- Game state ----------
var innings_per_game: int = 5
var cpu_defense_first: bool = true
var inning: int = 1
var half: int = 0            # 0 = top, 1 = bottom
var balls: int = 0
var strikes: int = 0
var outs: int = 0
var game_over: bool = false
var play_active: bool = false

# ---------- Signals ----------
signal count_changed(balls: int, strikes: int)
signal outs_changed(outs: int)
signal half_inning_started(inning: int, half: int)
signal play_state_changed(active: bool)
signal message(kind: String)
signal game_over_signal

# ---------- Cached refs ----------
var _runner_scene: PackedScene = null
var _runners_parent: Node = null
var _home: Node2D = null
var _b1: Node2D = null
var _b2: Node2D = null
var _b3: Node2D = null

func _ready() -> void:
	reset_game()
	_resolve_nodes()
	_log_refs("READY")

# ---------------- Public API ----------------
func reset_game() -> void:
	inning = 1
	half = 0
	balls = 0
	strikes = 0
	outs = 0
	game_over = false
	play_active = false
	count_changed.emit(balls, strikes)
	outs_changed.emit(outs)
	half_inning_started.emit(inning, half)

func start_play() -> void:
	if game_over:
		return
	if not play_active:
		play_active = true
		play_state_changed.emit(true)

func end_play() -> void:
	if play_active:
		play_active = false
		play_state_changed.emit(false)

func call_ball() -> void:
	if game_over:
		return
	start_play()
	balls += 1
	message.emit("BALL")
	if balls >= 4:
		message.emit("WALK")
		_reset_count()
		end_play()
	count_changed.emit(balls, strikes)

func call_strike() -> void:
	if game_over:
		return
	start_play()
	strikes += 1
	message.emit("STRIKE")
	if strikes >= 3:
		_register_out("K")
		end_play()
	count_changed.emit(balls, strikes)

func call_foul() -> void:
	if game_over:
		return
	start_play()
	if strikes < 2:
		strikes += 1
		count_changed.emit(balls, strikes)
	message.emit("FOUL")
	end_play()

func call_hit(is_hr: bool = false) -> void:
	if game_over:
		return
	start_play()
	if is_hr:
		message.emit("HR")
	else:
		message.emit("HIT")
		_reset_bases_for_new_play()
		_spawn_batter_runner()

func register_out(reason: String = "OUT") -> void:
	if game_over:
		return
	_register_out(reason)
	end_play()

# ---------------- Internals ----------------
func _register_out(reason: String) -> void:
	outs += 1
	message.emit(reason)
	_reset_count()
	outs_changed.emit(outs)
	if outs >= 3:
		_swap_sides()

func _swap_sides() -> void:
	outs = 0
	half = (half + 1) % 2
	if half == 0:
		inning += 1
		if inning > innings_per_game:
			_end_game()
			return
	count_changed.emit(balls, strikes)
	outs_changed.emit(outs)
	half_inning_started.emit(inning, half)

func _reset_count() -> void:
	balls = 0
	strikes = 0
	count_changed.emit(balls, strikes)

func _end_game() -> void:
	game_over = true
	play_active = false
	game_over_signal.emit()
	message.emit("GAME_OVER")
	play_state_changed.emit(false)

# ---------------- Runner / Base helpers ----------------
func _ensure_runner_scene_loaded() -> void:
	if _runner_scene_override != null:
		_runner_scene = _runner_scene_override
	else:
		if ResourceLoader.exists(RUNNER_SCENE_PATH):
			_runner_scene = load(RUNNER_SCENE_PATH) as PackedScene
		else:
			_runner_scene = null

func _resolve_nodes() -> void:
	var root := get_tree().get_current_scene()
	if root == null:
		return

	_ensure_runner_scene_loaded()

	# Runners parent
	_runners_parent = null
	if _runners_parent_path_override != NodePath():
		_runners_parent = root.get_node_or_null(_runners_parent_path_override)
	if _runners_parent == null:
		_runners_parent = root.get_node_or_null("Entities/Runners")
	if _runners_parent == null:
		_runners_parent = root.get_node_or_null(RUNNERS_PARENT_NAME)
	if _runners_parent == null:
		_runners_parent = Node.new()
		_runners_parent.name = RUNNERS_PARENT_NAME
		root.add_child(_runners_parent)

	# Bases
	_home = _resolve_specific_base(root, _home_path_override, ["base_home"], HOME_CANDIDATES, "HOME")
	_b1   = _resolve_specific_base(root, _b1_path_override, ["base1"], BASE1_CANDIDATES, "FIRST")
	_b2   = _resolve_specific_base(root, _b2_path_override, ["base2"], BASE2_CANDIDATES, "SECOND")
	_b3   = _resolve_specific_base(root, _b3_path_override, ["base3"], BASE3_CANDIDATES, "THIRD")

func _resolve_specific_base(root: Node, override_path: NodePath, groups: Array, name_candidates: Array, desired_tag: String) -> Node2D:
	# 1) explicit override
	if override_path != NodePath():
		var n := root.get_node_or_null(override_path) as Node2D
		if n != null:
			return n
	# 2) by group
	for g in groups:
		var by_group := get_tree().get_first_node_in_group(g)
		if by_group != null:
			return by_group as Node2D
	# 3) by name candidates with prefixes
	for nm in name_candidates:
		for p in NAME_PREFIXES:
			var path_str = p + nm
			var nn := root.get_node_or_null(path_str) as Node2D
			if nn != null:
				return nn
	# 4) by class + tag (BaseNode.name_tag)
	var found := _find_base_by_tag(root, desired_tag)
	if found != null:
		return found
	return null

func _find_base_by_tag(root: Node, desired_tag: String) -> Node2D:
	if root == null:
		return null
	var stack: Array = [root]
	while stack.size() > 0:
		var n := stack.pop_back() as Node
		var is_base := false
		if ClassDB.class_exists("BaseNode"):
			is_base = n is BaseNode
		else:
			is_base = n.has_method("new_play_reset") and n.has_signal("force_out") and n.has_signal("runner_safe")
		if is_base:
			var tag_val: String = ""
			if n.has_variable("name_tag"):
				tag_val = String(n.get("name_tag"))
			elif n.has_method("get"):
				var v = n.get("name_tag")
				if typeof(v) == TYPE_STRING:
					tag_val = v
			if tag_val != "":
				if tag_val.to_upper() == desired_tag.to_upper():
					return n as Node2D
			if desired_tag == "HOME":
				var nm_up := String(n.name).to_upper()
				if nm_up.find("HOME") != -1 or nm_up.find("PLATE") != -1:
					return n as Node2D
		var kids := n.get_children()
		for c in kids:
			stack.append(c)
	return null

func _get_bases_ok() -> bool:
	return is_instance_valid(_home) and is_instance_valid(_b1) and is_instance_valid(_b2) and is_instance_valid(_b3)

func _reset_bases_for_new_play() -> void:
	var root := get_tree().get_current_scene()
	if root == null:
		return
	var names: Array = []
	for i in HOME_CANDIDATES:
		names.append(i)
	names.append_array(BASE1_CANDIDATES)
	names.append_array(BASE2_CANDIDATES)
	names.append_array(BASE3_CANDIDATES)
	for n_name in names:
		for p in NAME_PREFIXES:
			var b := root.get_node_or_null(p + n_name)
			if b and b.has_method("new_play_reset"):
				b.new_play_reset()
	# Sweep any BaseNode we can find
	var stack: Array = [root]
	while stack.size() > 0:
		var n := stack.pop_back() as Node
		if ClassDB.class_exists("BaseNode") and n is BaseNode:
			if n.has_method("new_play_reset"):
				n.call("new_play_reset")
		var kids := n.get_children()
		for c in kids:
			stack.append(c)

# ---- property helpers for untyped Runner fallback ----
func _has_prop(obj: Object, prop: String) -> bool:
	var plist := obj.get_property_list()
	for p in plist:
		if p.has("name"):
			if String(p["name"]) == prop:
				return true
	return false

func _safe_set(obj: Object, prop: String, value) -> void:
	if _has_prop(obj, prop):
		obj.set(prop, value)

func _spawn_batter_runner() -> void:
	_resolve_nodes()

	var missing: Array = []
	if _runner_scene == null:
		missing.append("RunnerScene")
	if _home == null:
		missing.append("Home")
	if _b1 == null:
		missing.append("Base1")
	if _b2 == null:
		missing.append("Base2")
	if _b3 == null:
		missing.append("Base3")

	if missing.size() > 0:
		var dbg: String = "["
		for i in range(missing.size()):
			dbg += str(missing[i])
			if i < missing.size() - 1:
				dbg += ", "
		dbg += "]"
		push_warning("[GameManager] Missing: " + dbg)
		_debug_dump_missing()
		_log_refs("SPAWN_FAIL")
		push_warning("[GameManager] Missing Runner scene or base nodes; cannot spawn runner.")
		return

	var r := _runner_scene.instantiate()
	_runners_parent.add_child(r)

	# Prefer the typed path if your Runner script has `class_name Runner`
	if r is Runner:
		var rr := r as Runner
		rr.path = [_home.get_path(), _b1.get_path(), _b2.get_path(), _b3.get_path(), _home.get_path()]
		rr.is_forced = true
		rr.begin_at_path_index(0)
	else:
		# Untyped fallback: set properties only if they actually exist
		_safe_set(r, "path", [_home.get_path(), _b1.get_path(), _b2.get_path(), _b3.get_path(), _home.get_path()])
		_safe_set(r, "is_forced", true)
		if r.has_method("begin_at_path_index"):
			r.call("begin_at_path_index", 0)

	# Optional: connect signals for UI/logic
	if r.has_signal("forced_out") and not r.is_connected("forced_out", Callable(self, "_on_runner_forced_out")):
		r.connect("forced_out", Callable(self, "_on_runner_forced_out"))
	if r.has_signal("scored") and not r.is_connected("scored", Callable(self, "_on_runner_scored")):
		r.connect("scored", Callable(self, "_on_runner_scored"))
	if r.has_signal("reached_base") and not r.is_connected("reached_base", Callable(self, "_on_runner_reached_base")):
		r.connect("reached_base", Callable(self, "_on_runner_reached_base"))

# ---- Runner signal handlers ----
func _on_runner_forced_out(_base_idx: int) -> void:
	_register_out("OUT")

func _on_runner_scored() -> void:
	message.emit("SCORE")

func _on_runner_reached_base(_base_idx: int) -> void:
	pass

# ---------------- Diagnostics ----------------
func _debug_dump_missing() -> void:
	if _runner_scene == null:
		push_warning("[GameManager] Runner scene NOT found. Set via GameDirector.set_runner_scene(...) or update RUNNER_SCENE_PATH.")
	if _home == null:
		push_warning("[GameManager] Home NOT found. Acceptable names %s, groups 'base_home', override via GameDirector, or BaseNode.name_tag='HOME'." % [HOME_CANDIDATES])
	if _b1 == null:
		push_warning("[GameManager] Base1 NOT found. Try names %s (also under Entities/...), group 'base1', override, or BaseNode.name_tag='FIRST'." % [BASE1_CANDIDATES])
	if _b2 == null:
		push_warning("[GameManager] Base2 NOT found. Try names %s (also under Entities/...), group 'base2', override, or BaseNode.name_tag='SECOND'." % [BASE2_CANDIDATES])
	if _b3 == null:
		push_warning("[GameManager] Base3 NOT found. Try names %s (also under Entities/...), group 'base3', override, or BaseNode.name_tag='THIRD'." % [BASE3_CANDIDATES])

func _log_refs(phase: String) -> void:
	var root := get_tree().get_current_scene()
	var root_path: NodePath = NodePath("/")
	if root != null:
		root_path = root.get_path()

	var rs: String = "NULL"
	if _runner_scene != null:
		rs = "OK"

	var rp_path: NodePath = NodePath("(none)")
	if _runners_parent != null:
		rp_path = _runners_parent.get_path()

	var hp: NodePath = NodePath("(none)")
	if _home != null:
		hp = _home.get_path()

	var b1p: NodePath = NodePath("(none)")
	if _b1 != null:
		b1p = _b1.get_path()

	var b2p: NodePath = NodePath("(none)")
	if _b2 != null:
		b2p = _b2.get_path()

	var b3p: NodePath = NodePath("(none)")
	if _b3 != null:
		b3p = _b3.get_path()

	print("[GM:", phase, "] root=", str(root_path),
		" RunnerScene=", rs,
		" RunnersParent=", str(rp_path),
		" Home=", str(hp),
		" B1=", str(b1p),
		" B2=", str(b2p),
		" B3=", str(b3p))
