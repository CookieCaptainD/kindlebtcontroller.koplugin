return {
    -- 控制设备由插件自动识别：连接并配对手柄后，会按已配对设备的名称
    -- 解析出对应的 /dev/input/eventX（device_name 由插件自动写入 settings）。
    -- 仅在自动识别失败时才需要手动指定，例如：
    -- device_path = "/dev/input/event2",
    device_path = nil,

    -- 默认按键映射
    key_map = {
        [103] = "prev_page",
        [105] = "prev_page",
        [108] = "next_page",
        [106] = "next_page",
        [28] = "next_page",
        [304] = "next_page",
        [305] = "next_page",
        [306] = "prev_page",
        [307] = "prev_page",
        [308] = "push_progress",
        [309] = "next_page",
        [310] = "toggle_night_mode",
        [311] = "full_refresh",
        [312] = "pull_progress",
        [313] = "push_progress",
        [314] = "full_refresh",
        [316] = "go_home",
    },

    -- 摇杆映射
    joy_map = {
        [16] = {
            [-1] = "decrease_brightness",
            [1] = "increase_brightness",
        },
        [17] = {
            [-1] = "decrease_warmth",
            [1] = "increase_warmth",
        },
    }
}
