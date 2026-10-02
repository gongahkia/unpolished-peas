-- Scene-tree mutations used by the editor. They only edit serializable data.
local Scene = {}

local NODE_TYPES = {
  transform = true, sprite = true, tilemap = true, camera = true, panel = true,
  label = true, button = true, image = true, container = true, instance = true,
}

local function walk(node, visit)
  if visit(node) == false then return false end
  for _, child in ipairs(node.children or {}) do if walk(child, visit) == false then return false end end
  return true
end

local function default_properties(node_type)
  if node_type == "panel" then return { x = 40, y = 40, width = 240, height = 120, color = { .10, .18, .25, 1 } } end
  if node_type == "label" then return { x = 56, y = 56, text = "Label" } end
  if node_type == "button" then return { x = 56, y = 96, width = 160, height = 40, text = "Button" } end
  if node_type == "sprite" or node_type == "image" then return { x = 56, y = 56, width = 64, height = 64 } end
  return { x = 40, y = 40, width = 120, height = 40 }
end

function Scene.find(scene, node_id)
  local found
  walk(scene.root, function(node) if node.id == node_id then found = node; return false end end)
  return found
end

function Scene.parent_of(scene, node_id)
  local found
  walk(scene.root, function(node)
    for index, child in ipairs(node.children or {}) do if child.id == node_id then found = { node = node, index = index }; return false end end
  end)
  return found
end

function Scene.next_id(scene, node_type)
  local seen, number = {}, 1
  walk(scene.root, function(node) seen[node.id] = true end)
  local candidate = "node." .. node_type
  while seen[candidate] do number = number + 1; candidate = "node." .. node_type .. "_" .. number end
  return candidate
end

function Scene.add(scene, parent_id, node_type)
  if not NODE_TYPES[node_type] then return nil, "Unsupported scene node type" end
  local parent = Scene.find(scene, parent_id or scene.root.id)
  if not parent then return nil, "Parent node does not exist" end
  parent.children = parent.children or {}
  local node = { id = Scene.next_id(scene, node_type), type = node_type, properties = default_properties(node_type), children = {} }
  parent.children[#parent.children + 1] = node
  return node
end

function Scene.remove(scene, node_id)
  if node_id == scene.root.id then return nil, "The root node cannot be removed" end
  local parent = Scene.parent_of(scene, node_id)
  if not parent then return nil, "Node does not exist" end
  local removed = parent.node.children[parent.index]
  table.remove(parent.node.children, parent.index)
  return removed
end

function Scene.reparent(scene, node_id, parent_id)
  if node_id == scene.root.id then return nil, "The root node cannot be reparented" end
  local parent, next_parent = Scene.parent_of(scene, node_id), Scene.find(scene, parent_id)
  if not parent or not next_parent then return nil, "Node or destination parent does not exist" end
  local descendant = false
  walk(parent.node.children[parent.index], function(node) if node.id == parent_id then descendant = true; return false end end)
  if descendant then return nil, "A node cannot become a child of itself" end
  local node = parent.node.children[parent.index]
  table.remove(parent.node.children, parent.index)
  next_parent.children = next_parent.children or {}; next_parent.children[#next_parent.children + 1] = node
  return true
end

function Scene.each(scene, visit)
  return walk(scene.root, visit)
end

return Scene
