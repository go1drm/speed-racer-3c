extends SceneTree

func _init():
	var cfg := ConfigFile.new()
	var err := cfg.load("res://tune.cfg")
	if err != OK:
		print("加载 cfg 失败: ", err)
		quit()
		return
	
	print("=== [tune] 段漂移参数 ===")
	var drift_keys = ["friction_long_drift", "friction_lat_drift", "drift_slip_enabled",
		"drift_inertia_boost", "drift_centripetal_pull", "drift_min_speed",
		"drift_steer_mult", "drift_counter_enabled"]
	for k in drift_keys:
		var v = cfg.get_value("tune", k, "NOT_FOUND")
		print("  %s = %s (type=%d)" % [k, str(v), typeof(v)])
	
	print("\n=== [curves] 段 ===")
	if cfg.has_section("curves"):
		for cprop in cfg.get_section_keys("curves"):
			var pts = cfg.get_value("curves", cprop, null)
			if pts == null:
				print("  %s = NULL" % cprop)
			elif typeof(pts) == TYPE_ARRAY:
				print("  %s = Array[%d] first_y=%s" % [cprop, pts.size(), str(pts[0][1]) if pts.size() > 0 and typeof(pts[0]) == TYPE_ARRAY and pts[0].size() >= 2 else "?"])
			else:
				print("  %s = type=%d val=%s" % [cprop, typeof(pts), str(pts)])
	else:
		print("  [curves] 段不存在!")
	
	quit()
