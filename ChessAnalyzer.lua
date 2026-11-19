-- Chess Analyzer for Potassium (Roblox)
-- Reads the Chess Duels GUI, queries Lichess Cloud Eval, and draws a best-move arrow.
-- Start from a fresh game for reliable castling/en-passant tracking.

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local old = playerGui:FindFirstChild("ChessAnalyzer")
if old then old:Destroy() end

local imageToPiece = {
    ["103391638779841"] = "R", ["89764885361194"] = "N",
    ["80281927019132"] = "B", ["118620401880741"] = "Q",
    ["115164967554779"] = "K", ["115225807911302"] = "P",
    ["110879867494108"] = "r", ["136899428984320"] = "n",
    ["101214090182304"] = "b", ["94821738771746"] = "q",
    ["139566358250123"] = "k", ["70452849677091"] = "p",
}

local enabled, busy = false, false
local turn = "w"
local lastPlacement, lastFen = nil, nil
local castling = {K=true, Q=true, k=true, q=true}
local ep = "-"
local halfmove, fullmove = 0, 1

local chessGui = playerGui:WaitForChild("ChessUI")
local board = chessGui:WaitForChild("Screen"):WaitForChild("Root"):WaitForChild("Board")
local pieces = board:WaitForChild("Pieces")

local gui = Instance.new("ScreenGui")
gui.Name = "ChessAnalyzer"
gui.ResetOnSpawn = false
gui.DisplayOrder = 9999
gui.Parent = playerGui

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(250, 204)
panel.Position = UDim2.new(1, -270, 0, 100)
panel.BackgroundColor3 = Color3.fromRGB(25, 27, 34)
panel.BorderSizePixel = 0
panel.Active = true
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)

local function makeLabel(text, y, h, size)
    local x = Instance.new("TextLabel")
    x.BackgroundTransparency = 1
    x.Position = UDim2.fromOffset(11, y)
    x.Size = UDim2.new(1, -22, 0, h)
    x.Font = Enum.Font.Gotham
    x.TextSize = size or 13
    x.TextColor3 = Color3.fromRGB(235, 235, 240)
    x.TextXAlignment = Enum.TextXAlignment.Left
    x.Text = text
    x.Parent = panel
    return x
end

local function makeButton(text, y, color)
    local x = Instance.new("TextButton")
    x.Position = UDim2.fromOffset(10, y)
    x.Size = UDim2.new(1, -20, 0, 30)
    x.BackgroundColor3 = color
    x.TextColor3 = Color3.new(1, 1, 1)
    x.Font = Enum.Font.GothamBold
    x.TextSize = 13
    x.Text = text
    x.BorderSizePixel = 0
    x.Parent = panel
    Instance.new("UICorner", x).CornerRadius = UDim.new(0, 6)
    return x
end

local title = makeLabel("CHESS ANALYZER", 8, 23, 16)
title.Font = Enum.Font.GothamBold
local status = makeLabel("Status: OFF", 35, 20)
local bestLabel = makeLabel("Best move: --", 58, 24, 16)
local evalLabel = makeLabel("Evaluation: --", 84, 19)
local depthLabel = makeLabel("Depth: --", 104, 19)
local toggle = makeButton("ENABLE ANALYSIS", 132, Color3.fromRGB(35, 135, 80))
local sideButton = makeButton("TURN: WHITE", 168, Color3.fromRGB(65, 85, 130))

local overlay = Instance.new("Frame")
overlay.Name = "ChessAnalyzerArrow"
overlay.BackgroundTransparency = 1
overlay.BorderSizePixel = 0
overlay.Visible = false
overlay.ZIndex = 100
overlay.Parent = board
local shaft = Instance.new("Frame")
shaft.AnchorPoint = Vector2.new(0.5, 0.5)
shaft.BackgroundColor3 = Color3.fromRGB(35, 225, 105)
shaft.BackgroundTransparency = 0.12
shaft.BorderSizePixel = 0
shaft.ZIndex = 101
shaft.Parent = overlay
Instance.new("UICorner", shaft).CornerRadius = UDim.new(1, 0)
local head = Instance.new("TextLabel")
head.BackgroundTransparency = 1
head.AnchorPoint = Vector2.new(0.5, 0.5)
head.Size = UDim2.fromOffset(28, 28)
head.Font = Enum.Font.GothamBold
head.Text = "▶"
head.TextSize = 23
head.TextColor3 = Color3.fromRGB(35, 225, 105)
head.ZIndex = 102
head.Parent = overlay

local function clearArrow()
    overlay.Visible = false
end

local function readBoard()
    local squares = table.create(64, ".")
    for _, obj in ipairs(pieces:GetChildren()) do
        if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
            local id = obj.Image:match("%d+")
            local symbol = id and imageToPiece[id]
            if symbol then
                local file = math.floor(obj.Position.X.Scale * 8 + 0.5)
                local rankFromTop = math.floor(obj.Position.Y.Scale * 8 + 0.5)
                if file >= 0 and file < 8 and rankFromTop >= 0 and rankFromTop < 8 then
                    squares[rankFromTop * 8 + file + 1] = symbol
                end
            end
        end
    end
    return squares
end

local function placementFrom(squares)
    local rows = {}
    for rank = 0, 7 do
        local row, empty = "", 0
        for file = 0, 7 do
            local p = squares[rank * 8 + file + 1]
            if p == "." then
                empty += 1
            else
                if empty > 0 then row ..= tostring(empty); empty = 0 end
                row ..= p
            end
        end
        if empty > 0 then row ..= tostring(empty) end
        rows[#rows + 1] = row
    end
    return table.concat(rows, "/")
end

local function updateMetadata(previous, current)
    ep = "-"
    if not previous then return end
    local fromIndex, toIndex, changed = nil, nil, {}
    for i = 1, 64 do
        if previous[i] ~= current[i] then
            changed[#changed + 1] = i
            if previous[i] ~= "." and current[i] == "." then fromIndex = i end
            if current[i] ~= "." then toIndex = i end
        end
    end
    if #changed < 2 then return end

    local moved = fromIndex and previous[fromIndex] or nil
    local captured = toIndex and previous[toIndex] or "."

    if previous[61] == "K" and current[61] ~= "K" then castling.K, castling.Q = false, false end
    if previous[5] == "k" and current[5] ~= "k" then castling.k, castling.q = false, false end
    if previous[57] == "R" and current[57] ~= "R" then castling.Q = false end
    if previous[64] == "R" and current[64] ~= "R" then castling.K = false end
    if previous[1] == "r" and current[1] ~= "r" then castling.q = false end
    if previous[8] == "r" and current[8] ~= "r" then castling.k = false end
    if toIndex == 57 and captured == "r" then castling.Q = false end
    if toIndex == 64 and captured == "r" then castling.K = false end
    if toIndex == 1 and captured == "R" then castling.q = false end
    if toIndex == 8 and captured == "R" then castling.k = false end

    if moved == "P" and fromIndex and toIndex and math.abs(toIndex - fromIndex) == 16 then
        local file = (fromIndex - 1) % 8
        local targetRank = math.floor((fromIndex + toIndex) / 16)
        ep = string.char(97 + file) .. tostring(8 - targetRank)
    elseif moved == "p" and fromIndex and toIndex and math.abs(toIndex - fromIndex) == 16 then
        local file = (fromIndex - 1) % 8
        local targetRank = math.floor((fromIndex + toIndex) / 16)
        ep = string.char(97 + file) .. tostring(8 - targetRank)
    end

    if (moved and moved:lower() == "p") or captured ~= "." then halfmove = 0 else halfmove += 1 end
    if turn == "b" then fullmove += 1 end
    turn = turn == "w" and "b" or "w"
    sideButton.Text = turn == "w" and "TURN: WHITE" or "TURN: BLACK"
end

local function makeFen(squares)
    local rights = ""
    if castling.K then rights ..= "K" end
    if castling.Q then rights ..= "Q" end
    if castling.k then rights ..= "k" end
    if castling.q then rights ..= "q" end
    if rights == "" then rights = "-" end
    return placementFrom(squares) .. " " .. turn .. " " .. rights .. " " .. ep .. " " .. halfmove .. " " .. fullmove
end

local function drawArrow(uci)
    if type(uci) ~= "string" or #uci < 4 then clearArrow(); return end
    overlay.Position = UDim2.fromOffset(
        pieces.AbsolutePosition.X - board.AbsolutePosition.X,
        pieces.AbsolutePosition.Y - board.AbsolutePosition.Y
    )
    overlay.Size = UDim2.fromOffset(pieces.AbsoluteSize.X, pieces.AbsoluteSize.Y)
    local function point(square)
        local file = string.byte(square, 1) - 96
        local rank = tonumber(square:sub(2, 2))
        return (file - 0.5) * overlay.AbsoluteSize.X / 8,
               (8.5 - rank) * overlay.AbsoluteSize.Y / 8
    end
    local x1, y1 = point(uci:sub(1, 2))
    local x2, y2 = point(uci:sub(3, 4))
    local dx, dy = x2 - x1, y2 - y1
    local angle = math.deg(math.atan2(dy, dx))
    shaft.Position = UDim2.fromOffset((x1 + x2) / 2, (y1 + y2) / 2)
    shaft.Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy) * 0.78, 7)
    shaft.Rotation = angle
    head.Position = UDim2.fromOffset(x2, y2)
    head.Rotation = angle
    overlay.Visible = true
end

local function analyze()
    if busy or not enabled then return end
    busy = true
    status.Text = "Status: REQUESTING..."
    local ok, result = pcall(function()
        local squares = readBoard()
        local fen = makeFen(squares)
        lastFen = fen
        local url = "https://lichess.org/api/cloud-eval?fen=" .. HttpService:UrlEncode(fen) .. "&multiPv=1"
        local response = request({
            Url = url,
            Method = "GET",
            Headers = { ["Accept"] = "application/json" }
        })
        if response.StatusCode ~= 200 then
            return { error = "Cloud cache miss / HTTP " .. tostring(response.StatusCode) }
        end
        local data = HttpService:JSONDecode(response.Body)
        if not data.pvs or not data.pvs[1] or not data.pvs[1].moves then
            return { error = "No principal variation returned" }
        end
        return { fen = fen, data = data, move = data.pvs[1].moves:sub(1, 4) }
    end)
    busy = false
    if not ok then
        status.Text = "Error: " .. tostring(result)
        clearArrow()
        return
    end
    if result.error then
        status.Text = result.error
        clearArrow()
        return
    end
    local pv = result.data.pvs[1]
    bestLabel.Text = "Best: " .. result.move:sub(1, 2) .. " → " .. result.move:sub(3, 4)
    if pv.mate ~= nil then
        evalLabel.Text = "Evaluation: Mate " .. tostring(pv.mate)
    else
        evalLabel.Text = string.format("Evaluation: %+.2f", (pv.cp or 0) / 100)
    end
    depthLabel.Text = "Depth: " .. tostring(result.data.depth or "?")
    status.Text = "Status: ANALYZED"
    drawArrow(result.move)
    lastFen = result.fen
end

toggle.MouseButton1Click:Connect(function()
    enabled = not enabled
    toggle.Text = enabled and "DISABLE ANALYSIS" or "ENABLE ANALYSIS"
    toggle.BackgroundColor3 = enabled and Color3.fromRGB(155, 65, 65) or Color3.fromRGB(35, 135, 80)
    status.Text = enabled and "Status: ACTIVE" or "Status: OFF"
    if not enabled then clearArrow() else lastPlacement = nil; lastFen = nil end
end)

sideButton.MouseButton1Click:Connect(function()
    turn = turn == "w" and "b" or "w"
    sideButton.Text = turn == "w" and "TURN: WHITE" or "TURN: BLACK"
    lastFen = nil
    clearArrow()
end)

do
    local dragging, dragStart, startPos = false, nil, nil
    title.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = panel.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    game:GetService("UserInputService").InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

task.spawn(function()
    local previous = readBoard()
    lastPlacement = placementFrom(previous)
    while gui.Parent do
        task.wait(1.5)
        if enabled and not busy then
            local current = readBoard()
            local placement = placementFrom(current)
            if placement ~= lastPlacement then
                updateMetadata(previous, current)
                previous = current
                lastPlacement = placement
                lastFen = nil
                clearArrow()
            end
            local fen = makeFen(current)
            if fen ~= lastFen then analyze() end
        end
    end
end)

print("[Chess Analyzer] Loaded. Enable analysis in the GUI.")
