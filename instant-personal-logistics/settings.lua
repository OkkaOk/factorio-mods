
data:extend({
	{
		type = "bool-setting",
		name = "ipl-enabled",
		setting_type = "runtime-per-user",
		default_value = true,
	},
	{
		type = "bool-setting",
		name = "ipl-delete-trash-overflow",
		setting_type = "runtime-per-user",
		default_value = false,
	},
	{
		type = "bool-setting",
		name = "ipl-global-transfer",
		setting_type = "runtime-global",
		default_value = true,
	},
	{
      type = "int-setting",
      name = "ipl-ticks-per-transfer",
      setting_type = "runtime-global",
      default_value = 60,
		minimum_value = 1,
   },
})