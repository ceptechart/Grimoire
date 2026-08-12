local ElementRegistry = require "application.Canvas.ElementRegistry"

-- The layout tree behind ContainerElement: a recursive split, not a fixed grid.
--
-- A node is either a **leaf** (`{ id, weight }`, one child element) or a **split**
-- (`{ direction = "row"|"column", weight, children = { node, ... } }`). `"row"` lays
-- its children left to right, sharing the split's width; `"column"` stacks them top
-- to bottom, sharing its height. A node's `weight` is its share of space among its
-- *own* siblings -- meaningless on the root, which always fills the whole content
-- rect. `props.layout` holds the root, or nothing at all while the container is
-- empty (see the empty-array reasoning in Serialize.array -- "no key" is what "no
-- content" already means, so there's nothing to reconcile with an empty table).
--
-- This subsumes the old fixed "rows of cells" model as a special case -- a root
-- split of direction "column" whose children are direction-"row" splits -- while
-- adding the thing that model couldn't express: a child spanning the *other* axis,
-- because direction is a property of each split, not fixed at one level. Dropping an
-- element beside a specific element nests a small split around just that element;
-- dropping at the container's own outer edge inserts (or wraps into) a split at the
-- root, which is what makes "spans the whole column" and "spans the whole row" the
-- same operation at two different scopes rather than two different features. See
-- ContainerElement.dropTarget for where that split happens.
--
-- **Every function here treats a tree as immutable and returns a fresh one.** A tree
-- handed to SetProps is the old *or* new value of an undo step, and a command's
-- stored values have to still describe that step however far the user walks the
-- stack -- so an edit builds new tables rather than writing into ones that might
-- already be recorded.
local ContainerLayout = {}

local function isSplit(node)
    return node.children ~= nil
end

-- ── Reading ──────────────────────────────────────────────────────────────

-- Whether any leaf under `node` names an element still on the board. A dead subtree
-- (every leaf's element gone) drops out of the *live* layout entirely without the
-- stored tree being touched -- which is what lets undoing a delete put the element
-- back in the slot it came from, the same trick the old row model relied on.
local function isLive(node, document)
    if not isSplit(node) then
        return document:getById(node.id) ~= nil
    end
    for _, child in ipairs(node.children) do
        if isLive(child, document) then
            return true
        end
    end
    return false
end

ContainerLayout.isLive = isLive

-- The size `node` needs at its smallest: a leaf's is its element's minimum: a split's
-- is its live children's minimums laid out along its own direction (summed, plus
-- gaps) and maxed across the other. This is "the minimum row/column respects its
-- contents" applied at every depth, not just one.
function ContainerLayout.minSize(node, document, gap)
    if not isSplit(node) then
        local element = document:getById(node.id)
        if not element then
            return 0, 0
        end
        return ElementRegistry:minSizeOf(element, document)
    end

    local along, across = 0, 0
    local count = 0
    for _, child in ipairs(node.children) do
        if isLive(child, document) then
            local width, height = ContainerLayout.minSize(child, document, gap)
            local childAlong = node.direction == "row" and width or height
            local childAcross = node.direction == "row" and height or width
            along = along + childAlong
            across = math.max(across, childAcross)
            count = count + 1
        end
    end
    if count == 0 then
        return 0, 0
    end
    along = along + gap * (count - 1)

    if node.direction == "row" then
        return along, across
    end
    return across, along
end

-- Distributes `available` across items by weight, giving nothing less than its `min`.
--
-- Weights and minimums are independent -- an item can be weighted below what it can
-- shrink to -- so an item that comes out under its minimum is pinned there and taken
-- out of the pool, which changes the share everything else gets and can push the next
-- one under in turn. Hence the loop rather than a single pass.
local function distribute(items, available)
    local sizes = {}
    local pinned = {}
    local remaining = available
    local pool = 0

    for _, item in ipairs(items) do
        pool = pool + item.weight
    end

    local settled = false
    while not settled do
        settled = true
        for index, item in ipairs(items) do
            if not pinned[index] then
                local size = pool > 0 and remaining * (item.weight / pool) or 0
                if size < item.min then
                    pinned[index] = true
                    sizes[index] = item.min
                    remaining = remaining - item.min
                    pool = pool - item.weight
                    settled = false
                end
            end
        end
    end

    -- Only reachable when the minimums alone overflow the space, which the
    -- container's own minimum size normally prevents -- but a hand-edited file or an
    -- element type whose minimum grew between builds can still get here, and a
    -- negative size draws as an inside-out rectangle.
    remaining = math.max(remaining, 0)

    for index, item in ipairs(items) do
        if not pinned[index] then
            sizes[index] = pool > 0 and remaining * (item.weight / pool) or 0
        end
    end

    return sizes
end

ContainerLayout.distribute = distribute

-- The live geometry of a node's subtree, in world coordinates:
--
--   leaf   { id, element, x, y, width, height, raw = node }
--   split  { direction, x, y, width, height, children = { ... }, raw = node }
--
-- Dead leaves (and splits left with none) are simply absent from `children` -- the
-- stored tree is never touched to produce this. `raw` is a reference back to the
-- exact node in the tree that was resolved, identity-equal to something reachable
-- from `props.layout` -- which is what lets a caller (see CellResizeGesture) walk the
-- *live* tree to decide what should resize, and then write the change back to the
-- *stored* one without a second, index-based search that live-pruning would throw off.
local function resolveNode(node, document, x, y, width, height, gap)
    if not isSplit(node) then
        local element = document:getById(node.id)
        if not element then
            return nil
        end
        return { id = node.id, element = element, x = x, y = y, width = width, height = height, raw = node }
    end

    local items = {}
    for _, child in ipairs(node.children) do
        if isLive(child, document) then
            local minWidth, minHeight = ContainerLayout.minSize(child, document, gap)
            items[#items + 1] = {
                node = child,
                weight = child.weight or 1,
                min = node.direction == "row" and minWidth or minHeight,
            }
        end
    end
    if #items == 0 then
        return nil
    end

    local along = node.direction == "row" and width or height
    local sizes = distribute(items, along - gap * (#items - 1))

    local children = {}
    local cursor = node.direction == "row" and x or y
    for index, item in ipairs(items) do
        local size = sizes[index]
        local childX, childY, childWidth, childHeight
        if node.direction == "row" then
            childX, childY, childWidth, childHeight = cursor, y, size, height
        else
            childX, childY, childWidth, childHeight = x, cursor, width, size
        end
        children[#children + 1] = resolveNode(item.node, document, childX, childY, childWidth, childHeight, gap)
        cursor = cursor + size + gap
    end

    return { direction = node.direction, x = x, y = y, width = width, height = height, children = children, raw = node }
end

-- The live layout of a container's whole content rect: `{ x, y, width, height, root }`,
-- `root` being a resolved node (see resolveNode) or nil for an empty container.
function ContainerLayout.compute(tree, document, x, y, width, height, gap)
    local layout = { x = x, y = y, width = width, height = height }
    layout.root = tree and resolveNode(tree, document, x, y, width, height, gap) or nil
    return layout
end

-- The index of `child` within `parent.children`, by identity -- `parent` and `child`
-- are resolve()'s `.raw` references, which point into the exact stored tree, so this
-- is the true index there even when a dead sibling elsewhere makes the *resolved*
-- index different.
function ContainerLayout.indexOfRaw(parent, child)
    for index, candidate in ipairs(parent.children) do
        if candidate == child then
            return index
        end
    end
end

-- The path from a compute() result's root down to the resolved leaf naming `id`, as
-- a list of `{ resolved, resolvedIndex, rawIndex }` (root to leaf, exclusive of the
-- leaf itself): `resolved` is the split at that level, `resolvedIndex` the live
-- index of the next step within it (for "does a live sibling exist here"),
-- `rawIndex` that same step's index in the *stored* tree (for writing a change
-- back). Used by CellResizeGesture to find, and then rewrite, the boundary a drag
-- grabbed -- see the module comment on why `raw` is what makes that safe against
-- live-pruning having renumbered anything.
function ContainerLayout.pathToLeaf(root, id, path)
    path = path or {}
    if not root then
        return nil
    end
    if not root.children then
        return root.id == id and path or nil
    end
    for resolvedIndex, child in ipairs(root.children) do
        local extended = {}
        for index, entry in ipairs(path) do
            extended[index] = entry
        end
        extended[#extended + 1] = {
            resolved = root,
            resolvedIndex = resolvedIndex,
            rawIndex = ContainerLayout.indexOfRaw(root.raw, child.raw),
        }
        if not child.children then
            if child.id == id then
                return extended
            end
        else
            local found = ContainerLayout.pathToLeaf(child, id, extended)
            if found then
                return found
            end
        end
    end
    return nil
end

-- ── Editing ──────────────────────────────────────────────────────────────

local function copyNode(node)
    if not isSplit(node) then
        return { id = node.id, weight = node.weight or 1 }
    end
    local children = {}
    for index, child in ipairs(node.children) do
        children[index] = copyNode(child)
    end
    return { direction = node.direction, weight = node.weight or 1, children = children }
end

ContainerLayout.copy = copyNode

-- A new node's weight is the average of the ones it joins, so it lands the same size
-- as its neighbours rather than at whatever 1 happens to mean in that split.
local function meanWeight(nodes)
    if #nodes == 0 then
        return 1
    end
    local total = 0
    for _, node in ipairs(nodes) do
        total = total + (node.weight or 1)
    end
    return total / #nodes
end

local function newLeaf(id, weight)
    return { id = id, weight = weight }
end

local function containsId(node, id)
    if not isSplit(node) then
        return node.id == id
    end
    for _, child in ipairs(node.children) do
        if containsId(child, id) then
            return true
        end
    end
    return false
end

-- Turns `node` (already copied) into the thing that takes `node`'s old slot once
-- `childId` joins it in `direction`: a new sibling in `node`'s own children when
-- `node` already splits that way, or `node` wrapped with the new leaf inside a split
-- of that direction otherwise. Either way, the pair together ends up exactly where
-- `node` used to be -- so this is both "insert at the container's own outer edge"
-- (node = the whole tree) and "insert beside one specific element in a direction its
-- own row/column doesn't already run" (node = that element, found via insertBeside).
local function wrapOrExtend(node, direction, before, childId)
    if isSplit(node) and node.direction == direction then
        local leaf = newLeaf(childId, meanWeight(node.children))
        local children = {}
        if before then
            children[1] = leaf
            for index, child in ipairs(node.children) do
                children[index + 1] = child
            end
        else
            for index, child in ipairs(node.children) do
                children[index] = child
            end
            children[#children + 1] = leaf
        end
        return { direction = node.direction, weight = node.weight, children = children }
    end

    local leaf = newLeaf(childId, node.weight or 1)
    local children = before and { leaf, node } or { node, leaf }
    return { direction = direction, weight = node.weight, children = children }
end

-- Inserts `childId` beside the element named `targetId`, in `direction`, `before` or
-- after it. Ground truth for "which slot did the target have" comes from walking the
-- (already-copied) tree looking for `targetId` as a direct child: found there, either
-- it gains a sibling (same-direction parent) or it's wrapped (different direction) --
-- see wrapOrExtend. Otherwise this recurses into whichever child's subtree contains
-- the target and splices the result back in, leaving every other branch untouched.
local function insertBeside(node, targetId, direction, before, childId)
    if not isSplit(node) then
        -- Reached by recursing past a split with only one live child, which
        -- (post-collapse, see removeFrom) doesn't happen through normal editing --
        -- kept as the correct answer if it ever does.
        return node.id == targetId and wrapOrExtend(node, direction, before, childId) or node
    end

    local children = {}
    for index, child in ipairs(node.children) do
        if not isSplit(child) and child.id == targetId then
            if node.direction == direction then
                -- The target is a direct child of a split running the same way the
                -- drop asked for: it gains a plain sibling, same as any other insert
                -- within a row or column.
                if before then
                    children[#children + 1] = newLeaf(childId, meanWeight(node.children))
                end
                children[#children + 1] = copyNode(child)
                if not before then
                    children[#children + 1] = newLeaf(childId, meanWeight(node.children))
                end
            else
                children[index] = wrapOrExtend(copyNode(child), direction, before, childId)
            end
        elseif containsId(child, targetId) then
            children[index] = insertBeside(child, targetId, direction, before, childId)
        else
            children[index] = copyNode(child)
        end
    end

    return { direction = node.direction, weight = node.weight, children = children }
end

-- Adds a child per a drop descriptor (see ContainerElement.dropTarget):
--
--   { atRoot = true, direction, before }             -- spans the container's own
--                                                        outer edge
--   { targetId = id, direction, before }              -- beside one specific element
--
-- Both read the same way once the target is settled: gain a sibling if the thing
-- being split already runs that direction, otherwise wrap it. `atRoot` is what makes
-- "span the whole column" reachable at all -- it's the same wrapOrExtend a same-
-- direction insert-beside would use, just aimed at the tree's root instead of one
-- element's slot within it.
function ContainerLayout.insert(tree, drop, childId)
    if not tree then
        return newLeaf(childId, 1)
    end
    if drop.atRoot then
        return wrapOrExtend(copyNode(tree), drop.direction, drop.before, childId)
    end
    return insertBeside(copyNode(tree), drop.targetId, drop.direction, drop.before, childId)
end

-- Removes the leaf naming `id`, dropping any split left with nothing live and
-- collapsing one left with exactly one child -- its sole survivor takes over its
-- slot, inheriting its weight so that child's share among *its own* siblings one
-- level up doesn't change. Without the collapse, repeated drops and detaches would
-- leave the tree wrapped in single-child splits nobody put there on purpose, which is
-- as much a save-format concern (this is what a re-save has to stay clean through) as
-- a runtime one. Returns nil once nothing is left.
local function removeFrom(node, id)
    if not isSplit(node) then
        return node.id == id and nil or copyNode(node)
    end

    local children = {}
    for _, child in ipairs(node.children) do
        local kept
        if not isSplit(child) and child.id == id then
            kept = nil
        else
            kept = removeFrom(child, id)
        end
        if kept then
            children[#children + 1] = kept
        end
    end

    if #children == 0 then
        return nil
    end
    if #children == 1 then
        local sole = children[1]
        sole.weight = node.weight
        return sole
    end
    return { direction = node.direction, weight = node.weight, children = children }
end

ContainerLayout.remove = removeFrom

-- Rewrites the weights of one pair of sibling nodes so the first takes `weightA` and
-- the second `weightB` (see splitWeight for turning target sizes into weights).
-- `indexPath` locates their *parent* split as a chain of raw child indices from
-- `tree`'s root -- `{}` addresses `tree` itself, `{k}` its k-th stored child, and so
-- on. A fresh copy of `tree` is safe to index this way even though it's a different
-- set of tables from whatever produced the path (see pathToLeaf): copying preserves
-- child order and count exactly, and the path was built from raw indices in the
-- first place, never from anything live-pruning could have renumbered.
function ContainerLayout.withPairWeight(tree, indexPath, indexA, weightA, indexB, weightB)
    local root = copyNode(tree)
    local target = root
    for _, index in ipairs(indexPath) do
        target = target.children[index]
    end
    target.children[indexA].weight = weightA
    target.children[indexB].weight = weightB
    return root
end

-- Splits `total` weight between two neighbouring tracks in proportion to the sizes
-- they should end up at.
function ContainerLayout.splitWeight(totalWeight, sizeA, sizeB)
    local totalSize = sizeA + sizeB
    if totalSize <= 0 then
        return totalWeight / 2, totalWeight / 2
    end
    local weightA = totalWeight * (sizeA / totalSize)
    return weightA, totalWeight - weightA
end

-- ── Ids ──────────────────────────────────────────────────────────────────

function ContainerLayout.leafIds(node, out)
    out = out or {}
    if not isSplit(node) then
        out[#out + 1] = node.id
        return out
    end
    for _, child in ipairs(node.children) do
        ContainerLayout.leafIds(child, out)
    end
    return out
end

-- Rewrites every leaf's id through `idMap`, dropping (and collapsing around) any
-- that aren't in it -- used after a paste, which mints new ids for what came along
-- and leaves out anything that didn't.
function ContainerLayout.remapIds(node, idMap)
    if not isSplit(node) then
        local mapped = idMap[node.id]
        return mapped and { id = mapped, weight = node.weight or 1 } or nil
    end

    local children = {}
    for _, child in ipairs(node.children) do
        local mapped = ContainerLayout.remapIds(child, idMap)
        if mapped then
            children[#children + 1] = mapped
        end
    end

    if #children == 0 then
        return nil
    end
    if #children == 1 then
        local sole = children[1]
        sole.weight = node.weight
        return sole
    end
    return { direction = node.direction, weight = node.weight, children = children }
end

-- ── Persistence ──────────────────────────────────────────────────────────

-- Rebuilds a tree into the shape everything above assumes, dropping anything that
-- isn't it: a node that's neither a leaf nor a valid split, a leaf with no id, a
-- weight that isn't a positive number. Returns nil when nothing survives.
--
-- Called once per element on the way in from a file (see ElementRegistry:normalize),
-- which is the only place a board's props can be any shape at all -- a `.grimoire`
-- file is JSON anything could have written, and hand-editing one is a feature. Doing
-- it there rather than defending in every reader is the same bargain Element.fromData
-- makes: validate at the boundary, and trust the model afterwards.
function ContainerLayout.sanitize(node)
    if type(node) ~= "table" then
        return nil
    end

    local weight = tonumber(node.weight)
    weight = (weight and weight > 0) and weight or 1

    if node.children ~= nil then
        if type(node.children) ~= "table" then
            return nil
        end
        if node.direction ~= "row" and node.direction ~= "column" then
            return nil
        end
        local children = {}
        for _, child in ipairs(node.children) do
            local clean = ContainerLayout.sanitize(child)
            if clean then
                children[#children + 1] = clean
            end
        end
        if #children == 0 then
            return nil
        end
        if #children == 1 then
            children[1].weight = weight
            return children[1]
        end
        return { direction = node.direction, weight = weight, children = children }
    end

    if type(node.id) == "string" and node.id ~= "" then
        return { id = node.id, weight = weight }
    end
    return nil
end

return ContainerLayout
