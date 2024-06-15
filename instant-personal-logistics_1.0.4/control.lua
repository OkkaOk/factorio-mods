local logistics = {}

function logistics.on_tick()
	if game.tick % settings.global["ipl-ticks-per-transfer"].value ~= 0 then
		return
	end

	for _, player in pairs(game.players) do
		if player == nil or player.character == nil then goto next_player end

		if not player.force.character_logistic_requests or not player.mod_settings["ipl-enabled"].value then
			goto next_player
		end

		if player.character_personal_logistic_requests_enabled then
			player.print("Your personal logistics are controlled by the mod Instant Personal Logistics. No need to enable this")
			player.character_personal_logistic_requests_enabled = false
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

	local inv_contents = player_inv.get_contents()
	if player.cursor_stack ~= nil and player.cursor_stack.valid_for_read then
		inv_contents[player.cursor_stack.name] = (inv_contents[player.cursor_stack.name] or 0) + player.cursor_stack.count
	end

	-- Every logistic request is fulfilled 
	local requests_fulfilled = true

	for i=1, player.character.request_slot_count do
		local request = player.get_personal_logistic_slot(i)
		if request == nil or request.name == nil then
			goto next_request
		end

		local existing_count = (inv_contents[request.name] or 0) + player_ammo.get_item_count(request.name)
		if request.min ~= nil and existing_count < request.min then
			local needed = request.min - existing_count

			local took_from_network = network.remove_item({ name = request.name, count = needed })

			-- Network didn't have this item
			if took_from_network <= 0 then
				requests_fulfilled = false
				goto next_request
			end

			if took_from_network < needed then
				requests_fulfilled = false
			end

			local ammo_inserted = player_ammo.insert({ name = request.name, count = took_from_network })
			took_from_network = took_from_network - ammo_inserted

			if took_from_network > 0 then
				local inv_inserted = player_inv.insert({ name = request.name, count = took_from_network })
				took_from_network = took_from_network - inv_inserted
			end

			-- Player inventory couldn't fit all the items we took from logistics network so we need to put them back
			if took_from_network > 0 then
				network.insert({ name = request.name, count = took_from_network })
				requests_fulfilled = false
			end
		end

		-- Insert items that go over the max amount to trash
		if player_trash ~= nil and request.max ~= nil and existing_count > request.max then
			local moved = player_trash.insert({ name = request.name, count = existing_count - request.max })
			if moved > 0 then
				player_inv.remove({ name = request.name, count = moved })
			end
		end

		::next_request::
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
	for item_name, count in pairs(player_trash.get_contents()) do
		local inserted = network.insert({ name = item_name, count = count })

		if trash_overflow_deletion then
			player_trash.remove({ name = item_name, count = count })
		else
			if inserted > 0 then
				player_trash.remove({ name = item_name, count = inserted })
			end

			-- Trash didn't fit into logistics network
			if inserted < count then
				trash_emptied = false
			end
		end
	end

	return trash_emptied
end

script.on_event(defines.events.on_tick, logistics.on_tick)