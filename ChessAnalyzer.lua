-- Chess Analyzer for Potassium (Roblox)
-- Reads the Chess Duels GUI, queries the local Stockfish HTTP bridge, and draws the best-move arrow.
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
local retryPending = false
local boardFlipped = false -- vertical orientation (rank 1 at top)
local boardFlippedX = false -- horizontal orientation (file a at right)
local playerSide = nil
local turn = nil
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
local engineLabel = makeLabel("Engine: Local Stockfish (waiting...)", 124, 18, 11)
local toggle = makeButton("ENABLE ANALYSIS", 148, Color3.fromRGB(35, 135, 80))
local autoButton = makeButton("AUTO MOVE: OFF", 184, Color3.fromRGB(65, 75, 95))
local turnLabel = makeLabel("TO MOVE: SYNCING...", 220, 20, 12)
local playerSideLabel = makeLabel("YOU: DETECTING SIDE...", 256, 20, 12)

local function setTurn(newTurn)
    if newTurn ~= "w" and newTurn ~= "b" then return end
    if turn ~= newTurn then
        turn = newTurn
        lastFen = nil
    end
    turnLabel.Text = newTurn == "w" and "TO MOVE: WHITE" or "TO MOVE: BLACK"
end

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
        local fileAPos, fileHPos
        for _, cell in ipairs(squaresGui:GetChildren()) do
            if cell.Name == "Cell" then
                local rankLabel = cell:FindFirstChild("Rank")
                local fileLabel = cell:FindFirstChild("File")

                if fileLabel and fileLabel:IsA("TextLabel") then
                    if fileLabel.Text:lower() == "a" then
                        fileAPos = cell.AbsolutePosition.X + cell.AbsoluteSize.X / 2
                    elseif fileLabel.Text:lower() == "h" then
                        fileHPos = cell.AbsolutePosition.X + cell.AbsoluteSize.X / 2
                    end
                end

                if rankLabel and rankLabel:IsA("TextLabel") and rankLabel.Text == "1" then
                    local boardMidY = squaresGui.AbsolutePosition.Y + squaresGui.AbsoluteSize.Y / 2
                    local cellMidY = cell.AbsolutePosition.Y + cell.AbsoluteSize.Y / 2
                    if math.abs(cellMidY - boardMidY) > 5 then
                        boardFlipped = cellMidY < boardMidY
                        playerSide = boardFlipped and "b" or "w"
                    end
                end
            end
        end

        -- The File labels reveal horizontal mirroring independently of color.
        if fileAPos and fileHPos and math.abs(fileAPos - fileHPos) > 5 then
            boardFlippedX = fileAPos > fileHPos
        end
        if playerSide then return playerSide end
    end

    -- Fallback if labels are temporarily hidden during the match UI transition.
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
                local file = boardFlippedX and (7 - screenFile) or screenFile
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
    local sources, destinations = {}, {}
    ep = "-"

    for i = 1, 64 do
        if previous[i] ~= current[i] then
            if previous[i] ~= "." then sources[#sources + 1] = {index=i, piece=previous[i]} end
            if current[i] ~= "." then
                destinations[#destinations + 1] = {index=i, piece=current[i], captured=previous[i]}
            end
        end
    end
    if #sources == 0 or #destinations == 0 then return false end

    local function sideOf(piece)
        if not piece or piece == "." then return nil end
        return piece == piece:upper() and "w" or "b"
    end

    local movedSide, chosen, ambiguous = nil, nil, false
    for _, source in ipairs(sources) do
        for _, destination in ipairs(destinations) do
            local side = sideOf(source.piece)
            local sameSide = side == sideOf(destination.piece)
            local exact = source.piece == destination.piece
            local promotion = source.piece:lower() == "p" and destination.piece:lower() ~= "p"
            if sameSide and (exact or promotion) then
                if movedSide and movedSide ~= side then ambiguous = true else movedSide = side end
                local candidate = {from=source.index, to=destination.index, piece=source.piece}
                if not chosen or source.piece:lower() == "k" or promotion then chosen = candidate end
            end
        end
    end

    -- Bulk board refreshes and incomplete animation frames are ignored.
    if ambiguous or not movedSide or not chosen then return false end

    local movedPiece, captured = chosen.piece, false
    for _, source in ipairs(sources) do
        local p, i = source.piece, source.index
        if p == "K" and i == 61 then castling.K, castling.Q = false, false end
        if p == "k" and i == 5 then castling.k, castling.q = false, false end
        if p == "R" and i == 57 then castling.Q = false end
        if p == "R" and i == 64 then castling.K = false end
        if p == "r" and i == 1 then castling.q = false end
        if p == "r" and i == 8 then castling.k = false end
    end
    for _, destination in ipairs(destinations) do
        local oldPiece, i = destination.captured, destination.index
        if oldPiece == "R" and i == 57 then castling.Q = false end
        if oldPiece == "R" and i == 64 then castling.K = false end
        if oldPiece == "r" and i == 1 then castling.q = false end
        if oldPiece == "r" and i == 8 then castling.k = false end
        if oldPiece ~= "." then captured = true end
    end

    if movedPiece:lower() == "p" and math.abs(chosen.to - chosen.from) == 16 then
        local file = (chosen.from - 1) % 8
        local middle = math.floor((chosen.from + chosen.to) / 2)
        local rank = 8 - math.floor((middle - 1) / 8)
        ep = string.char(97 + file) .. tostring(rank)
    end
    if #sources > #destinations then captured = true end -- en-passant capture
    if movedPiece:lower() == "p" or captured then halfmove = 0 else halfmove += 1 end
    if movedSide == "b" then fullmove += 1 end

    setTurn(movedSide == "w" and "b" or "w")
    return true
end

local function makeFen(squares)
    if turn ~= "w" and turn ~= "b" then return nil end
    local rights = ""
    if castling.K then rights ..= "K" end
    if castling.Q then rights ..= "Q" end
    if castling.k then rights ..= "k" end
    if castling.q then rights ..= "q" end
    if rights == "" then rights = "-" end
    return placementFrom(squares) .. " " .. turn .. " " .. rights .. " " .. ep .. " " .. halfmove .. " " .. fullmove
end

local function normalizeTurn(value, key)
    if type(value) == "boolean" then
        if key == "iswhiteturn" or key == "whitetomove" then return value and "w" or "b" end
        if key == "isblackturn" or key == "blacktomove" then return value and "b" or "w" end
    elseif type(value) == "string" then
        local v = value:lower()
        if v == "w" or v == "white" then return "w" end
        if v == "b" or v == "black" then return "b" end
    end
    return nil
end

local function findTurnInState(value, depth)
    if type(value) ~= "table" or depth > 5 then return nil end
    local recognized = {
        turn=true, currentturn=true, nextturn=true, sidetomove=true,
        side_to_move=true, activecolor=true, activecolour=true,
        turncolor=true, turncolour=true, iswhiteturn=true,
        isblackturn=true, whitetomove=true, blacktomove=true
    }
    for key, child in pairs(value) do
        local keyName = tostring(key):lower():gsub("[%s%-%_]", "")
        if recognized[keyName] then
            local parsed = normalizeTurn(child, keyName)
            if parsed then return parsed end
        end
    end
    for _, child in pairs(value) do
        if type(child) == "table" then
            local parsed = findTurnInState(child, depth + 1)
            if parsed then return parsed end
        end
    end
    return nil
end

local function attachTurnRemote()
    local replicated = game:GetService("ReplicatedStorage")
    local remotes = replicated:FindFirstChild("ChessRemotes")
    local updateRemote = remotes and remotes:FindFirstChild("Update")
    if updateRemote and updateRemote:IsA("RemoteEvent") then
        updateRemote.OnClientEvent:Connect(function(...)
            local args = {...}
            if type(args[1]) == "string" and #args >= 2 then
                local keyName = args[1]:lower():gsub("[%s%-%_]", "")
                if keyName:find("turn") then
                    local parsed = normalizeTurn(args[2], keyName)
                    if parsed then setTurn(parsed) end
                end
            end
            for _, value in ipairs(args) do
                local parsed = findTurnInState(value, 0)
                if parsed then setTurn(parsed); break end
            end
        end)
    end
end
attachTurnRemote()

local function boardPoint(square)
    local file = string.byte(square, 1) - 96
    local rank = tonumber(square:sub(2, 2))
    local x = boardFlippedX
        and (8.5 - file) * pieces.AbsoluteSize.X / 8
        or (file - 0.5) * pieces.AbsoluteSize.X / 8
    local y = boardFlipped
        and (rank - 0.5) * pieces.AbsoluteSize.Y / 8
        or (8.5 - rank) * pieces.AbsoluteSize.Y / 8
    return x, y
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

local function moveIsOnBoard(uci)
    local fromFile = string.byte(uci, 1) - 96
    local fromRank = tonumber(uci:sub(2, 2))
    local toFile = string.byte(uci, 3) - 96
    local toRank = tonumber(uci:sub(4, 4))
    if not fromRank or not toRank then return false end

    local squares = readBoard()
    local fromIndex = (8 - fromRank) * 8 + fromFile
    local toIndex = (8 - toRank) * 8 + toFile
    return squares[fromIndex] == "." and squares[toIndex] ~= "."
end

local function autoPlayMove(uci)
    if not autoMoveEnabled then return end
    if autoMoveBusy then
        status.Text = "AUTO: another move is still running"
        return
    end
    if not playerSide then
        status.Text = "AUTO: waiting for player-side detection"
        return
    end
    if not turn then
        status.Text = "AUTO: waiting for turn sync"
        return
    end
    if turn ~= playerSide then
        status.Text = "AUTO: waiting for your turn"
        return
    end
    if type(uci) ~= "string" or #uci < 4 then
        status.Text = "AUTO: invalid move from engine"
        return
    end
    if #uci > 4 then
        status.Text = "AUTO: promotion requires manual choice"
        return
    end

    local fromFile = string.byte(uci, 1) - 96
    local fromRank = tonumber(uci:sub(2, 2))
    local toFile = string.byte(uci, 3) - 96
    local toRank = tonumber(uci:sub(4, 4))
    if fromFile < 1 or fromFile > 8 or toFile < 1 or toFile > 8
        or not fromRank or fromRank < 1 or fromRank > 8
        or not toRank or toRank < 1 or toRank > 8 then
        status.Text = "AUTO: invalid UCI coordinates"
        return
    end

    -- Do not click a move if the source square isn't occupied by our piece.
    local squares = readBoard()
    local fromIndex = (8 - fromRank) * 8 + fromFile
    local piece = squares[fromIndex]
    if not piece or piece == "." then
        status.Text = "AUTO: source " .. uci:sub(1, 2) .. " is empty"
        warn("[Chess Analyzer] Auto move cancelled: source square is empty")
        return
    end
    local pieceSide = piece == piece:upper() and "w" or "b"
    if pieceSide ~= playerSide then
        status.Text = "AUTO: source piece is not yours"
        warn("[Chess Analyzer] Auto move cancelled: source piece side mismatch")
        return
    end

    autoMoveBusy = true
    status.Text = "AUTO: sending " .. uci:sub(1, 2) .. " → " .. uci:sub(3, 4)
    task.spawn(function()
        local ok, err = pcall(function()
            local confirmed = false

            for attempt = 1, 2 do
                if moveIsOnBoard(uci) then
                    confirmed = true
                    break
                end

                status.Text = "AUTO: click attempt " .. attempt .. "/2"
                clickBoardSquare(uci:sub(1, 2))
                task.wait(0.16)
                clickBoardSquare(uci:sub(3, 4))
                task.wait(0.25)

                -- Chess Duels sometimes asks for a second tap to confirm.
                local confirmHint = board:FindFirstChild("ConfirmHint")
                if confirmHint and confirmHint.Visible then
                    clickBoardSquare(uci:sub(3, 4))
                    task.wait(0.25)
                end

                -- Wait for the source to clear and the destination to fill.
                local deadline = os.clock() + 1.35
                repeat
                    if moveIsOnBoard(uci) then
                        confirmed = true
                        break
                    end
                    task.wait(0.08)
                until os.clock() >= deadline

                if confirmed then break end
            end

            if confirmed then
                lastFen = nil
                retryPending = false
                status.Text = "AUTO: MOVE CONFIRMED"
            else
                status.Text = "AUTO: GAME DID NOT ACCEPT CLICK"
                warn("[Chess Analyzer] Auto move was not reflected on the board: " .. uci)
            end
        end)

        autoMoveBusy = false
        if not ok then
            status.Text = "AUTO INPUT ERROR: " .. tostring(err)
            warn("[Chess Analyzer] " .. tostring(err))
        end
    end)
end

local LOCAL_STOCKFISH_URL = "http://127.0.0.1:8765/analyze"
local LOCAL_STOCKFISH_DEPTH = 18

local function analyze()
    if busy or not enabled then return end
    if os.clock() < nextApiRequestAt then
        retryPending = true
        return
    end

    busy = true
    nextApiRequestAt = os.clock() + 1
    status.Text = "Status: LOCAL STOCKFISH..."

    local requestedFen = makeFen(readBoard())
    if not requestedFen then
        busy = false
        status.Text = "Waiting for game turn sync..."
        return
    end
    local ok, result = pcall(function()
        local response = request({
            Url = LOCAL_STOCKFISH_URL,
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json",
                ["Accept"] = "application/json"
            },
            Body = HttpService:JSONEncode({
                fen = requestedFen,
                depth = LOCAL_STOCKFISH_DEPTH,
                movetime_ms = autoMoveEnabled and 550 or 800
            })
        })

        local statusCode = tonumber(response.StatusCode)
        local body = HttpService:JSONDecode(response.Body or "{}")
        if statusCode ~= 200 then
            return {
                error = body.error or ("Local server HTTP " .. tostring(statusCode or "?")),
                statusCode = statusCode
            }
        end
        if not body.data or not body.data.pvs or not body.data.pvs[1] then
            return { error = "Local Stockfish returned an invalid response" }
        end
        local move = body.move or body.data.bestmove or body.data.pvs[1].moves
        if type(move) ~= "string" or #move < 4 then
            return { error = "Stockfish did not return a valid best move" }
        end
        return {
            fen = requestedFen,
            data = body.data,
            move = move:sub(1, 4)
        }
    end)

    busy = false

    if not ok then
        retryPending = true
        nextApiRequestAt = os.clock() + 5
        status.Text = "LOCAL SERVER OFFLINE — run start_server.bat"
        warn("[Chess Analyzer] Local Stockfish connection failed: " .. tostring(result))
        return
    end

    if result.error then
        retryPending = true
        nextApiRequestAt = os.clock() + 5
        status.Text = tostring(result.error)
        clearArrow()
        return
    end

    retryPending = false
    lastFen = result.fen
    local pv = result.data.pvs[1]
    if result.data.engine then
        engineLabel.Text = "Engine: " .. tostring(result.data.engine)
    else
        engineLabel.Text = "Engine: Local Stockfish"
    end
    bestLabel.Text = "Best: " .. result.move:sub(1, 2) .. " → " .. result.move:sub(3, 4)
    if pv.mate ~= nil then
        evalLabel.Text = "Evaluation: Mate " .. tostring(pv.mate)
    else
        evalLabel.Text = string.format("Evaluation: %+.2f", (pv.cp or 0) / 100)
    end
    depthLabel.Text = "Depth: " .. tostring(result.data.depth or "?")
    status.Text = "Status: LOCAL ANALYSIS"
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
    -- Detect orientation before the first FEN snapshot.
    detectPlayerSide()
    local previous = readBoard()
    local pendingPlacement, pendingCount = nil, 0
    lastPlacement = placementFrom(previous)
    local startPlacement = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR"

    if lastPlacement == startPlacement then
        castling = {K=true, Q=true, k=true, q=true}
        ep, halfmove, fullmove = "-", 0, 1
        setTurn("w")
    else
        turnLabel.Text = "TO MOVE: WAITING FOR SYNC"
    end

    while gui.Parent do
        task.wait(0.25)
        local oldFlip, oldFlipX = boardFlipped, boardFlippedX
        local detected = detectPlayerSide()
        if detected then
            playerSideLabel.Text = detected == "w" and "YOU: WHITE (AUTO)" or "YOU: BLACK (AUTO)"
        else
            playerSideLabel.Text = "YOU: SIDE NOT DETECTED"
        end

        local current = readBoard()
        local placement = placementFrom(current)
        local boardReady = true

        if placement == startPlacement and lastPlacement ~= startPlacement then
            pendingPlacement, pendingCount = nil, 0
            castling = {K=true, Q=true, k=true, q=true}
            ep, halfmove, fullmove = "-", 0, 1
            setTurn("w")
            previous = current
            lastPlacement = placement
            lastFen = nil
            clearArrow()
        elseif placement ~= lastPlacement then
            if oldFlip ~= boardFlipped or oldFlipX ~= boardFlippedX then
                -- A coordinate remap is not a chess move.
                previous = current
                lastPlacement = placement
                lastFen = nil
            else
                local confirmedMove = updateMetadata(previous, current)
                if confirmedMove then
                    previous = current
                    lastPlacement = placement
                    lastFen = nil
                    clearArrow()
                else
                    -- Wait for two identical complete snapshots. Some board updates
                    -- contain intermediate frames that are not a legal single move.
                    if pendingPlacement == placement then
                        pendingCount += 1
                    else
                        pendingPlacement = placement
                        pendingCount = 1
                    end

                    if pendingCount >= 2 then
                        -- The board is stable but its animation diff was ambiguous.
                        -- Keep the last known turn instead of freezing analysis forever.
                        previous = current
                        lastPlacement = placement
                        lastFen = nil
                        pendingPlacement, pendingCount = nil, 0
                        clearArrow()
                        status.Text = "Board synced; using current turn"
                    else
                        boardReady = false
                        status.Text = "Syncing board animation..."
                    end
                end
            end
        end

        if enabled and not busy and boardReady then
            if autoMoveEnabled and (not playerSide or turn ~= playerSide) then
                status.Text = "AUTO: WAITING FOR YOUR TURN"
            else
                local fen = makeFen(current)
                if fen and (fen ~= lastFen or retryPending) and os.clock() >= nextApiRequestAt then
                    analyze()
                elseif not fen then
                    status.Text = "Waiting for turn sync..."
                end
            end
        end
    end
end)

print("[Chess Analyzer] Loaded. Enable analysis in the GUI.")
