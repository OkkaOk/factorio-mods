local logistics = {}

function logistics.on_tick()
	if game.tick % settings.global["ipl-ticks-per-transfer"].value ~= 0 then
		return
	end

	for _, player in pairs(game.players) do
		if player == nil or player.character == nil then goto next_player end

		if player.force.character_logistic_requests == false or player.mod_settings["ipl-enabled"].value == false then
			goto next_player
		end

		local logistic_point = player.get_requester_point();
		if logistic_point == nil or logistic_point.enabled == false then
			goto next_player
		end

		if settings.global["ipl-global-transfer"].value then
			for surface, networks in pairs(player.force.logistic_networks) do
				for _, network in ipairs(networks) do
					local requests_fulfilled = logistics.handle_requests(network, player)
					local trash_emptied = logistics.handle_trash(network, player)

					-- Saves a bit of time if there are a lot of logistic networks
					if requests_fulfilled and trash_emptied then
						goto next_player
					end
				end
			end
		else
			local network = player.surface.find_logistic_network_by_position(player.position, player.force)
			if network ~= nil then
				logistics.handle_requests(network, player)
				logistics.handle_trash(network, player)
			end
		end

		::next_player::
	end
end

---@param network LuaLogisticNetwork
---@param player LuaPlayer
function logistics.handle_requests(network, player)
	-- Only personal logistic networks have value less than 4294967295, and we don't want to take items from there
	-- There must be a better way to do this but I couldn't find one
	if network.robot_limit < 4294967295 then
		return false
	end

	local player_inv = player.get_inventory(defines.inventory.character_main)
	local player_ammo = player.get_inventory(defines.inventory.character_ammo)
	local player_trash = player.get_inventory(defines.inventory.character_trash)
	if player_inv == nil or player_ammo == nil then return false end

	-- Every logistic request is fulfilled
	local requests_fulfilled = true

	local logistic_point = player.get_requester_point();
	if (logistic_point == nil) then
		return false
	end

	for i = 1, logistic_point.sections_count do
		local section = logistic_point.get_section(i);
		if section.active == false then
			goto next_section
		end

		for j = 1, section.filters_count do
			local request = section.get_slot(j);
			if request == nil or request.value == nil or request.value.name == nil then
				goto next_request
			end

			local existing_count = player_inv.get_item_count(request.value.name) + player_ammo.get_item_count(request.value.name)
			if player.cursor_stack ~= nil and player.cursor_stack.valid_for_read and player.cursor_stack.name == request.value.name then
				existing_count = existing_count + player.cursor_stack.count
			end

			-- Take items from the network and insert them into the player's inventory
			if request.min ~= nil and existing_count < request.min then
				local needed = request.min - existing_count
				local took_from_network = network.remove_item({ name = request.value.name, count = needed })

				if took_from_network < needed then
					requests_fulfilled = false

					-- Network didn't have this item
					if took_from_network <= 0 then
						goto next_request
					end
				end

				local ammo_inserted = player_ammo.insert({ name = request.value.name, count = took_from_network })
				took_from_network = took_from_network - ammo_inserted

				if took_from_network > 0 then
					local inv_inserted = player_inv.insert({ name = request.value.name, count = took_from_network })
					took_from_network = took_from_network - inv_inserted
				end

				-- Player inventory couldn't fit all the items we took from logistics network so we need to put them back
				if took_from_network > 0 then
					network.insert({ name = request.value.name, count = took_from_network })
					requests_fulfilled = false
				end
			end

			-- Insert items that go over the max amount to trash
			if request.max ~= nil and player_trash ~= nil and existing_count > request.max then
				local to_remove = player_trash.insert({ name = request.value.name, count = existing_count - request.max })

				if to_remove > 0 then
					local ammo_removed = player_ammo.remove({ name = request.value.name, count = to_remove })
					to_remove = to_remove - ammo_removed
				end

				if to_remove > 0 then
					local items_removed = player_inv.remove({ name = request.value.name, count = to_remove })
					to_remove = to_remove - items_removed
				end
			end

			::next_request::
		end

		::next_section::
	end

	return requests_fulfilled
end

---@param network LuaLogisticNetwork
---@param player LuaPlayer
function logistics.handle_trash(network, player)
	local player_trash = player.get_inventory(defines.inventory.character_trash)
	local trash_overflow_deletion = player.mod_settings["ipl-delete-trash-overflow"].value

	if player_trash == nil then return true end

	local trash_emptied = true

	-- Remove trash
	for i, item in pairs(player_trash.get_contents()) do
		local inserted = network.insert({ name = item.name, count = item.count })

		if trash_overflow_deletion then
			player_trash.remove({ name = item.name, count = item.count })
		else
			if inserted > 0 then
				player_trash.remove({ name = item.name, count = inserted })
			end

			-- Trash didn't fit into logistics network
			if inserted < item.count then
				trash_emptied = false
			end
		end
	end

	return trash_emptied
end

script.on_event(defines.events.on_tick, logistics.on_tick)
