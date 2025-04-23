local logistics = {}

---@type { [integer]: integer }
local player_last_updated = {}

---@param player LuaPlayer?
function logistics.handle_player(player)
	if not player or not logistics.should_process_player(player) then return end

	local logistic_point = player.get_requester_point();
	if logistic_point == nil then return end

	if not logistic_point.enabled and not player.mod_settings["ipl-force-enabled"].value then return end

	if settings.global["ipl-global-transfer"].value then
		logistics.transfer_from_all_networks(player, logistic_point)
	else
		logistics.transfer_from_local_network(player, logistic_point)
	end

	player_last_updated[player.index] = game.tick
end

---@param player LuaPlayer
---@param logistic_point LuaLogisticPoint
function logistics.transfer_from_all_networks(player, logistic_point)
	for surface, networks in pairs(player.force.logistic_networks) do
		if settings.global["ipl-limit-surface"].value and surface ~= player.surface.name then
			goto next_surface
		end

		for _, network in ipairs(networks) do
			if logistics.is_personal_network(network) then goto next_network end

			local requests_fulfilled = logistics.handle_requests(network, player, logistic_point)
			local trash_emptied = logistics.handle_trash(network, player)

			-- Saves a bit of time if there are a lot of logistic networks
			if requests_fulfilled and trash_emptied then return end

			::next_network::
		end

		::next_surface::
	end
end

---@param player LuaPlayer
---@param logistic_point LuaLogisticPoint
function logistics.transfer_from_local_network(player, logistic_point)
	local network = player.surface.find_logistic_network_by_position(player.position, player.force)
	if not network then return end

	logistics.handle_requests(network, player, logistic_point)
	logistics.handle_trash(network, player)
end

---@param network LuaLogisticNetwork
---@param player LuaPlayer
---@param logistic_point LuaLogisticPoint
function logistics.handle_requests(network, player, logistic_point)
	if not player.mod_settings["ipl-requests-enabled"].value then return true end

	local main_inv = player.get_inventory(defines.inventory.character_main)
	local ammo_inv = player.get_inventory(defines.inventory.character_ammo)
	local trash_inv = player.get_inventory(defines.inventory.character_trash)
	if not main_inv then return true end

	-- Every logistic request is fulfilled
	local requests_fulfilled = true

	for _, filter in ipairs(logistic_point.filters) do
		if not filter or not filter.name then goto next_request end

		---@type ItemIDAndQualityIDPair
		local item_identifier = { name = filter.name, quality = filter.quality }

		local existing_count = logistics.get_existing_item_count(player, item_identifier, main_inv, ammo_inv)

		if not logistics.insert_needed_items(network, filter, existing_count, main_inv, ammo_inv) then
			requests_fulfilled = false
		end

		logistics.trash_excess_items(filter, existing_count, main_inv, ammo_inv, trash_inv)

		::next_request::
	end

	return requests_fulfilled
end


---@param player LuaPlayer
---@param item ItemIDAndQualityIDPair
---@param main_inv LuaInventory
---@param ammo_inv LuaInventory?
function logistics.get_existing_item_count(player, item, main_inv, ammo_inv)
	local count = main_inv.get_item_count(item)

	if ammo_inv then
		count = count + ammo_inv.get_item_count(item)
	end

	if player.cursor_stack and player.cursor_stack.valid_for_read and
		player.cursor_stack.name == item.name and
		player.cursor_stack.quality.name == item.quality then

		count = count + player.cursor_stack.count
	end

	return count
end

-- Take the required amount of items from the network and give them to the player
---@param network LuaLogisticNetwork
---@param request CompiledLogisticFilter
---@param existing_count integer
---@param main_inv LuaInventory
---@param ammo_inv LuaInventory?
function logistics.insert_needed_items(network, request, existing_count, main_inv, ammo_inv)
	if not request.count then return true end

	local needed = request.count - existing_count
	if needed <= 0 then return true end

	local took = network.remove_item({ name = request.name, count = needed, quality = request.quality })
	if took <= 0 then return false end -- Network didn't have this item

	local remaining = took
	if ammo_inv then
		remaining = remaining - ammo_inv.insert({ name = request.name, count = remaining, quality = request.quality })
	end

	if remaining > 0 then
		remaining = remaining - main_inv.insert({ name = request.name, count = remaining, quality = request.quality })
	end

	-- Player inventory couldn't fit all the items we took from logistics network so we need to put them back
	if remaining > 0 then
		network.insert({ name = request.name, count = took, quality = request.quality })
		return false
	end

	return took >= needed
end

-- Insert items that go over the max amount to trash
---@param request CompiledLogisticFilter
---@param existing_count integer
---@param main_inv LuaInventory
---@param ammo_inv LuaInventory?
---@param trash_inv LuaInventory?
function logistics.trash_excess_items(request, existing_count, main_inv, ammo_inv, trash_inv)
	if not request.max_count or not trash_inv then return end

	local excess = existing_count - request.max_count
	if excess <= 0 then return end

	local to_trash = trash_inv.insert({ name = request.name, count = excess, quality = request.quality })
	local leftover = to_trash

	if leftover > 0 and ammo_inv then
		leftover = leftover - ammo_inv.remove({ name = request.name, count = leftover, quality = request.quality })
	end

	if leftover > 0 then
		leftover = leftover - main_inv.remove({ name = request.name, count = leftover, quality = request.quality })
	end
end

-- Move items from trash slots to the network
---@param network LuaLogisticNetwork
---@param player LuaPlayer
function logistics.handle_trash(network, player)
	if not player.mod_settings["ipl-trash-enabled"].value then return true end

	local player_trash = player.get_inventory(defines.inventory.character_trash)
	local trash_overflow_deletion = player.mod_settings["ipl-delete-trash-overflow"].value

	if not player_trash then return true end

	local trash_emptied = true

	-- Remove trash
	for i, item in pairs(player_trash.get_contents()) do
		local inserted = network.insert({ name = item.name, count = item.count, quality = item.quality })
		local to_remove = inserted
		if trash_overflow_deletion then
			to_remove = item.count
		end

		local trash_removed = player_trash.remove({ name = item.name, count = to_remove, quality = item.quality })

		-- Trash didn't fit into logistics network
		if trash_removed < item.count then
			trash_emptied = false
		end
	end

	return trash_emptied
end

---@param network LuaLogisticNetwork
function logistics.is_personal_network(network)
	-- Only personal logistic networks have value less than 4294967295, and we don't want to take items from there
	-- There must be a better way to do this but I couldn't find one
	return network.robot_limit < 4294967295
end

---@param player LuaPlayer
function logistics.should_process_player(player)
	if not player.character then return false end
	if player_last_updated[player.index] == game.tick then return false end -- Already updated this tick
	if not player.force.character_logistic_requests then return false end
	return true
end

script.on_event(defines.events.on_player_main_inventory_changed, function (event)
	logistics.handle_player(game.get_player(event.player_index))
end)

script.on_event(defines.events.on_player_ammo_inventory_changed, function (event)
	logistics.handle_player(game.get_player(event.player_index))
end)

script.on_event(defines.events.on_player_cursor_stack_changed, function (event)
	logistics.handle_player(game.get_player(event.player_index))
end)

script.on_event(defines.events.on_entity_logistic_slot_changed, function (event)
	if event.player_index ~= nil then
		logistics.handle_player(game.get_player(event.player_index))
	end
end)

script.on_event(defines.events.on_tick, function (event)
	local frequency = settings.global["ipl-ticks-per-transfer"].value

	if event.tick % frequency ~= 0 then return end

	for _, player in pairs(game.connected_players) do
		logistics.handle_player(player)
	end
end)