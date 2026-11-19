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
local autoMoveEnabled, autoMoveBusy = false, false
local nextApiRequestAt = 0
local apiBlockedUntil = 0
local retryPending = false
local boardFlipped = false
local playerSide = nil
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
panel.Size = UDim2.fromOffset(270, 294)
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
local engineLabel = makeLabel("Engine: Lichess Cloud (version unknown)", 124, 18, 11)
local toggle = makeButton("ENABLE ANALYSIS", 148, Color3.fromRGB(35, 135, 80))
local autoButton = makeButton("AUTO MOVE: OFF", 184, Color3.fromRGB(65, 75, 95))
local sideButton = makeButton("TURN: WHITE", 220, Color3.fromRGB(65, 85, 130))
local playerSideLabel = makeLabel("YOU: DETECTING SIDE...", 256, 20, 12)

local overlay = Instance.new("Frame")
overlay.Name = "ChessAnalyzerArrow"
overlay.BackgroundTransparency = 1
overlay.BorderSizePixel = 0
overlay.Visible = false
overlay.ZIndex = 100
overlay.Parent = board

local function makeArrowPart(name, color, transparency, z)
    local part = Instance.new("Frame")
    part.Name = name
    part.AnchorPoint = Vector2.new(0.5, 0.5)
    part.BackgroundColor3 = color
    part.BackgroundTransparency = transparency or 0
    part.BorderSizePixel = 0
    part.ZIndex = z
    part.Parent = overlay
    Instance.new("UICorner", part).CornerRadius = UDim.new(1, 0)
    return part
end

local arrowGlow = makeArrowPart("Glow", Color3.fromRGB(25, 255, 145), 0.76, 100)
local shaft = makeArrowPart("Shaft", Color3.fromRGB(240, 255, 248), 0.02, 101)
local headA = makeArrowPart("ArrowHeadA", Color3.fromRGB(240, 255, 248), 0.02, 102)
local headB = makeArrowPart("ArrowHeadB", Color3.fromRGB(240, 255, 248), 0.02, 102)

local startDot = Instance.new("Frame")
startDot.Name = "StartDot"
startDot.AnchorPoint = Vector2.new(0.5, 0.5)
startDot.Size = UDim2.fromOffset(12, 12)
startDot.BackgroundColor3 = Color3.fromRGB(25, 255, 145)
startDot.BorderSizePixel = 0
startDot.ZIndex = 103
startDot.Parent = overlay
Instance.new("UICorner", startDot).CornerRadius = UDim.new(1, 0)
local startStroke = Instance.new("UIStroke", startDot)
startStroke.Color = Color3.fromRGB(245, 255, 250)
startStroke.Thickness = 2

local endRing = Instance.new("Frame")
endRing.Name = "TargetRing"
endRing.AnchorPoint = Vector2.new(0.5, 0.5)
endRing.Size = UDim2.fromOffset(23, 23)
endRing.BackgroundTransparency = 1
endRing.BorderSizePixel = 0
endRing.ZIndex = 103
endRing.Parent = overlay
Instance.new("UICorner", endRing).CornerRadius = UDim.new(1, 0)
local endStroke = Instance.new("UIStroke", endRing)
endStroke.Color = Color3.fromRGB(25, 255, 145)
endStroke.Thickness = 3

local endDot = Instance.new("Frame")
endDot.Name = "TargetDot"
endDot.AnchorPoint = Vector2.new(0.5, 0.5)
endDot.Size = UDim2.fromOffset(5, 5)
endDot.BackgroundColor3 = Color3.fromRGB(245, 255, 250)
endDot.BorderSizePixel = 0
endDot.ZIndex = 104
endDot.Parent = overlay

local function clearArrow()
    overlay.Visible = false
end

local function detectPlayerSide()
    local squaresGui = board:FindFirstChild("Squares")
    if squaresGui then
        for _, cell in ipairs(squaresGui:GetChildren()) do
            if cell.Name == "Cell" then
                local rankLabel = cell:FindFirstChild("Rank")
                if rankLabel and rankLabel:IsA("TextLabel") and rankLabel.Text == "1" then
                    local boardMidY = squaresGui.AbsolutePosition.Y + squaresGui.AbsoluteSize.Y / 2
                    local cellMidY = cell.AbsolutePosition.Y + cell.AbsoluteSize.Y / 2
                    if math.abs(cellMidY - boardMidY) > 5 then
                        boardFlipped = cellMidY < boardMidY
                        playerSide = boardFlipped and "b" or "w"
                        return playerSide
                    end
                end
            end
        end
    end

    -- Fallback: infer which army is physically closest to the bottom edge.
    local whiteBottom, blackBottom = 0, 0
    for _, obj in ipairs(pieces:GetChildren()) do
        if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
            local id = obj.Image:match("%d+")
            local symbol = id and imageToPiece[id]
            if symbol and obj.Position.Y.Scale > 0.50 then
                if symbol == symbol:upper() then whiteBottom += 1 else blackBottom += 1 end
            end
        end
    end
    if whiteBottom ~= blackBottom and math.max(whiteBottom, blackBottom) >= 4 then
        playerSide = whiteBottom > blackBottom and "w" or "b"
        boardFlipped = playerSide == "b"
        return playerSide
    end
    return nil
end

local function readBoard()
    local squares = table.create(64, ".")
    for _, obj in ipairs(pieces:GetChildren()) do
        if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
            local id = obj.Image:match("%d+")
            local symbol = id and imageToPiece[id]
            if symbol then
                local screenFile = math.floor(obj.Position.X.Scale * 8 + 0.5)
                local screenRank = math.floor(obj.Position.Y.Scale * 8 + 0.5)
                local file = boardFlipped and (7 - screenFile) or screenFile
                local rankFromTop = boardFlipped and (7 - screenRank) or screenRank
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

local function boardPoint(square)
    local file = string.byte(square, 1) - 96
    local rank = tonumber(square:sub(2, 2))
    if boardFlipped then
        return (8.5 - file) * pieces.AbsoluteSize.X / 8,
               (rank - 0.5) * pieces.AbsoluteSize.Y / 8
    end
    return (file - 0.5) * pieces.AbsoluteSize.X / 8,
           (8.5 - rank) * pieces.AbsoluteSize.Y / 8
end

local function setLine(part, x1, y1, x2, y2, width)
    local dx, dy = x2 - x1, y2 - y1
    part.Position = UDim2.fromOffset((x1 + x2) / 2, (y1 + y2) / 2)
    part.Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy), width)
    part.Rotation = math.deg(math.atan2(dy, dx))
end

local function drawArrow(uci)
    if type(uci) ~= "string" or #uci < 4 then clearArrow(); return end
    uci = uci:sub(1, 4)
    overlay.Position = UDim2.fromOffset(
        pieces.AbsolutePosition.X - board.AbsolutePosition.X,
        pieces.AbsolutePosition.Y - board.AbsolutePosition.Y
    )
    overlay.Size = UDim2.fromOffset(pieces.AbsoluteSize.X, pieces.AbsoluteSize.Y)
    local x1, y1 = boardPoint(uci:sub(1, 2))
    local x2, y2 = boardPoint(uci:sub(3, 4))
    local dx, dy = x2 - x1, y2 - y1
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 1 then clearArrow(); return end
    local ux, uy = dx / length, dy / length
    local angle = math.atan2(dy, dx)
    local tipX, tipY = x2 - ux * 11, y2 - uy * 11

    setLine(arrowGlow, x1, y1, tipX, tipY, 14)
    setLine(shaft, x1, y1, tipX, tipY, 4)
    local a1, a2 = angle + math.rad(150), angle - math.rad(150)
    setLine(headA, x2, y2, x2 + math.cos(a1) * 16, y2 + math.sin(a1) * 16, 4)
    setLine(headB, x2, y2, x2 + math.cos(a2) * 16, y2 + math.sin(a2) * 16, 4)
    startDot.Position = UDim2.fromOffset(x1, y1)
    endRing.Position = UDim2.fromOffset(x2, y2)
    endDot.Position = UDim2.fromOffset(x2, y2)
    overlay.Visible = true
end

local function clickBoardSquare(square)
    local x, y = boardPoint(square)
    x += pieces.AbsolutePosition.X
    y += pieces.AbsolutePosition.Y
    local vim = game:GetService("VirtualInputManager")
    vim:SendMouseMoveEvent(x, y, game)
    task.wait(0.06)
    vim:SendMouseButtonEvent(x, y, 0, true, game, 0)
    task.wait(0.06)
    vim:SendMouseButtonEvent(x, y, 0, false, game, 0)
end

local function autoPlayMove(uci)
    if not autoMoveEnabled or autoMoveBusy or not playerSide or turn ~= playerSide then return end
    if type(uci) ~= "string" or #uci < 4 then return end
    if #uci > 4 then
        status.Text = "AUTO: promotion requires manual choice"
        return
    end

    local fromFile = string.byte(uci, 1) - 96
    local fromRank = tonumber(uci:sub(2, 2))
    if fromFile < 1 or fromFile > 8 or not fromRank or fromRank < 1 or fromRank > 8 then return end
    local squares = readBoard()
    local piece = squares[(8 - fromRank) * 8 + fromFile]
    if not piece or piece == "." then
        status.Text = "AUTO: source square not found"
        return
    end
    local pieceSide = piece == piece:upper() and "w" or "b"
    if pieceSide ~= playerSide then
        status.Text = "AUTO: detected side mismatch"
        return
    end

    autoMoveBusy = true
    status.Text = "AUTO: " .. uci:sub(1, 2) .. " → " .. uci:sub(3, 4)
    task.spawn(function()
        local ok, err = pcall(function()
            clickBoardSquare(uci:sub(1, 2))
            task.wait(0.12)
            clickBoardSquare(uci:sub(3, 4))
            task.wait(0.15)

            -- This board may request a second tap to confirm the destination.
            local hint = board:FindFirstChild("ConfirmHint")
            if hint and hint.Visible then
                clickBoardSquare(uci:sub(3, 4))
            end
        end)
        task.wait(0.65)
        autoMoveBusy = false
        if not ok then
            status.Text = "AUTO CLICK ERROR: " .. tostring(err)
        end
    end)
end

local function analyze()
    if busy or not enabled then return end

    local now = os.clock()
    if now < apiBlockedUntil then
        retryPending = true
        status.Text = "Lichess rate limit: " .. math.ceil(apiBlockedUntil - now) .. "s"
        return
    end
    if now < nextApiRequestAt then
        retryPending = true
        status.Text = "Waiting before next API request..."
        return
    end

    busy = true
    nextApiRequestAt = now + 8
    status.Text = "Status: REQUESTING..."

    local requestedFen = makeFen(readBoard())
    local ok, result = pcall(function()
        local url = "https://lichess.org/api/cloud-eval?fen=" .. HttpService:UrlEncode(requestedFen) .. "&multiPv=1&variant=standard"
        local response = request({
            Url = url,
            Method = "GET",
            Headers = { ["Accept"] = "application/json" }
        })
        local statusCode = tonumber(response.StatusCode)
        if statusCode == 429 then
            return { http = 429, fen = requestedFen }
        elseif statusCode == 404 then
            return { http = 404, fen = requestedFen }
        elseif statusCode ~= 200 then
            return { http = statusCode or -1, fen = requestedFen }
        end

        local data = HttpService:JSONDecode(response.Body)
        if not data.pvs or not data.pvs[1] or not data.pvs[1].moves then
            return { error = "No principal variation returned", fen = requestedFen }
        end
        return { fen = requestedFen, data = data, move = data.pvs[1].moves:sub(1, 4) }
    end)

    busy = false

    if not ok then
        retryPending = true
        nextApiRequestAt = math.max(nextApiRequestAt, os.clock() + 15)
        status.Text = "Network/API error. Retry in 15s"
        warn("[Chess Analyzer] " .. tostring(result))
        return
    end

    if result.http == 429 then
        apiBlockedUntil = os.clock() + 60
        nextApiRequestAt = apiBlockedUntil
        retryPending = true
        status.Text = "Lichess rate limited: waiting 60s"
        return
    elseif result.http == 404 then
        lastFen = result.fen
        retryPending = false
        status.Text = "Position not in Lichess cache (404)"
        clearArrow()
        return
    elseif result.http then
        retryPending = true
        nextApiRequestAt = math.max(nextApiRequestAt, os.clock() + 15)
        status.Text = "Lichess HTTP " .. tostring(result.http) .. " — retry in 15s"
        return
    elseif result.error then
        lastFen = result.fen
        retryPending = false
        status.Text = result.error
        clearArrow()
        return
    end

    retryPending = false
    lastFen = result.fen
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
    autoPlayMove(result.move)
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

autoButton.MouseButton1Click:Connect(function()
    autoMoveEnabled = not autoMoveEnabled
    autoButton.Text = autoMoveEnabled and "AUTO MOVE: ON" or "AUTO MOVE: OFF"
    autoButton.BackgroundColor3 = autoMoveEnabled and Color3.fromRGB(155, 95, 35) or Color3.fromRGB(65, 75, 95)
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
        local detected = detectPlayerSide()
        if detected then
            playerSideLabel.Text = detected == "w" and "YOU: WHITE (AUTO)" or "YOU: BLACK (AUTO)"
        else
            playerSideLabel.Text = "YOU: SIDE NOT DETECTED"
        end
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
            local now = os.clock()
            if now < apiBlockedUntil then
                status.Text = "Lichess rate limit: " .. math.ceil(apiBlockedUntil - now) .. "s"
            elseif (fen ~= lastFen or retryPending) and now >= nextApiRequestAt then
                analyze()
            end
        end
    end
end)

print("[Chess Analyzer] Loaded. Enable analysis in the GUI.")
