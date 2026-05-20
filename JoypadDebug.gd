extends Node
## ============================================================
##  手柄输入调试工具 (Autoload 单例)
##  按 F5 开启/关闭调试模式
##  开启后: 控制台实时打印手柄按钮和轴的输入事件
##  用于确认手柄按钮的正确 button_index
## ============================================================
##
##  Godot 4.x JoyButton 枚举参考:
##    0  = A (Cross)
##    1  = B (Circle)
##    2  = X (Square)
##    3  = Y (Triangle)
##    4  = Back/Select
##    5  = Guide/Home
##    6  = Start/Menu
##    7  = Left Stick Click (L3)
##    8  = Right Stick Click (R3)
##    9  = Left Shoulder (LB)
##    10 = Right Shoulder (RB)
##    11 = D-Pad Up
##    12 = D-Pad Down
##    13 = D-Pad Left
##    14 = D-Pad Right
##    15 = Misc1
##    16-21 = Paddle1-4, Touchpad
##
##  Godot 4.x JoyAxis 枚举参考:
##    0 = Left Stick X
##    1 = Left Stick Y
##    2 = Right Stick X
##    3 = Right Stick Y
##    4 = Left Trigger (LT/L2)
##    5 = Right Trigger (RT/R2)
## ============================================================

var _debug_active: bool = false

const BUTTON_NAMES: Dictionary = {
	0: "A (Cross)",
	1: "B (Circle)",
	2: "X (Square)",
	3: "Y (Triangle)",
	4: "Back/Select",
	5: "Guide/Home",
	6: "Start/Menu",
	7: "L3 (Left Stick Click)",
	8: "R3 (Right Stick Click)",
	9: "LB (Left Shoulder)",
	10: "RB (Right Shoulder)",
	11: "D-Pad Up",
	12: "D-Pad Down",
	13: "D-Pad Left",
	14: "D-Pad Right",
}

const AXIS_NAMES: Dictionary = {
	0: "Left Stick X",
	1: "Left Stick Y",
	2: "Right Stick X",
	3: "Right Stick Y",
	4: "LT (Left Trigger)",
	5: "RT (Right Trigger)",
}

func _unhandled_input(event: InputEvent) -> void:
	# F5 切换调试模式
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F5 or event.physical_keycode == KEY_F5:
			_debug_active = not _debug_active
			if _debug_active:
				print("═══════════════════════════════════════════")
				print("[JoypadDebug] 手柄调试模式 开启")
				print("  按任意手柄按钮/摇杆查看 button_index/axis")
				print("  再按 F5 关闭")
				print("═══════════════════════════════════════════")
				# 打印已连接的手柄
				for i in range(8):
					var name: String = Input.get_joy_name(i)
					if name != "":
						print("  手柄 device=%d: %s" % [i, name])
			else:
				print("[JoypadDebug] 手柄调试模式 关闭")
			get_viewport().set_input_as_handled()
			return

	if not _debug_active:
		return

	# 打印手柄按钮事件
	if event is InputEventJoypadButton:
		var btn: InputEventJoypadButton = event
		var btn_name: String = BUTTON_NAMES.get(btn.button_index, "Unknown(%d)" % btn.button_index)
		if btn.pressed:
			print("[JoypadDebug] 按钮按下: device=%d button_index=%d → %s" % [btn.device, btn.button_index, btn_name])

	# 打印手柄轴事件 (只打印绝对值 > 0.3 的, 避免刷屏)
	elif event is InputEventJoypadMotion:
		var motion: InputEventJoypadMotion = event
		if absf(motion.axis_value) > 0.3:
			var axis_name: String = AXIS_NAMES.get(motion.axis, "Unknown(%d)" % motion.axis)
			print("[JoypadDebug] 轴输入: device=%d axis=%d value=%.2f → %s" % [motion.device, motion.axis, motion.axis_value, axis_name])
