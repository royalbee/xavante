-----------------------------------------------------------------------------
-- Xavante webDAV file repository
-- Author: Javier Guerra
-- Copyright (c) 2005 Javier Guerra
-----------------------------------------------------------------------------

local lfs = require "lfs"
require "xavante.mime"

local source_mt = { __index = {} }
local source = source_mt.__index

local resource_mt = { __index = {} }
local resource = resource_mt.__index

-- on partial requests seeks the file to
-- the start of the requested range and returns
-- the number of bytes requested.
-- on full requests returns nil
local function getrange (range, f)
        if not range then return nil end

        local s,e, r_A, r_B = string.find (range, "(%d*)%s*-%s*(%d*)")
        if s and e then
                r_A = tonumber (r_A)
                r_B = tonumber (r_B)

                if r_A then
                        f:seek ("set", r_A)
                        if r_B then return r_B + 1 - r_A end
                else
                        if r_B then f:seek ("end", - r_B) end
                end
        end

        return nil
end

function source:getRoot ()
	return self.rootDir
end


function source:getResource (rootUrl, path)
	local diskpath = self.rootDir .. path
	if diskpath:sub(-1) == '/' then
		diskpath = diskpath:sub(1, -2)
	end
	local attr = lfs.attributes (diskpath)
	if not attr then return end

	local _,_,pfx = string.find (rootUrl, "^(.*/)[^/]-$")

	if attr.mode == "directory" and string.sub (path, -1) ~= "/" then
		path = path .."/"
	end
	
	return setmetatable ({
		source = self,
		path = path,
		diskpath = diskpath,
		attr = attr,
		pfx = pfx
	}, resource_mt)
end

function source:createResource (rootUrl, path)
	local diskpath = self.rootDir .. path
	if diskpath:sub(-1) == '/' then
		diskpath = diskpath:sub(1, -2)
	end
	local attr = lfs.attributes (diskpath)
	if not attr then
		io.open (diskpath, "wb"):close ()
		attr = lfs.attributes (diskpath)
	end
	
	local _,_,pfx = string.find (rootUrl, "^(.*/)[^/]-$")

	return setmetatable ({
		source = self,
		path = path,
		diskpath = diskpath,
		attr = attr,
		pfx = pfx
	}, resource_mt)
end

function source:createCollection (rootUrl, path)
	local diskpath = self.rootDir .. path
	return lfs.mkdir (diskpath)
end

local _liveprops = {}

_liveprops["DAV:creationdate"] = function (self)
	return os.date ("!%a, %d %b %Y %H:%M:%S GMT", self.attr.change)
end

_liveprops["DAV:displayname"] = function (self)
	local name = ""
	for part in string.gfind (self.path, "[^/]+") do
		name = part
	end
	return name
end

_liveprops["DAV:source"] = function (self)
	return self:getHRef ()
end


_liveprops["DAV:supportedlock"] = function (self)
	return [[<D:lockentry>
<D:lockscope><D:exclusive/></D:lockscope>
<D:locktype><D:write/></D:locktype>
</D:lockentry>
<D:lockentry>
<D:lockscope><D:shared/></D:lockscope>
<D:locktype><D:write/></D:locktype>
</D:lockentry>]]
end


_liveprops["DAV:getlastmodified"] = function (self)
	return os.date ("!%a, %d %b %Y %H:%M:%S GMT", self.attr.modification)
end

_liveprops["DAV:resourcetype"] = function (self)
	if self.attr.mode == "directory" then
		return "<D:collection/>"
	else
		return ""
	end
end

_liveprops["DAV:getcontenttype"] = function (self)
	return self:getContentType ()
end
_liveprops["DAV:getcontentlength"] = function (self)
	return self:getContentSize ()
end

function resource:getContentType ()
	if self.attr.mode == "directory" then
		return "httpd/unix-directory"
	end
	local _,_,exten = string.find (self.path, "%.([^.]*)$")
	exten = exten or ""
	return xavante.mimetypes [exten] or ""
end

function resource:getContentSize (range)
	if self.attr.mode == "file" then
		local range_len = nil

		if range then
			local f = io.open (self.diskpath, "rb")
			if f then
				range_len = getrange (range, f)
				f:close ()
			end
		end
		return (range_len or self.attr.size), range_len ~= nil
	else return 0, false
	end
end

function resource:getContentData (range)
	local function gen ()
		local f = io.open (self.diskpath, "rb")
		if not f then
			return
		end

		local left = getrange (range, f) or self.attr.size
		local block
		repeat
			block = f:read (math.min (8192, left))
			if block then
				left = left - string.len (block)
				coroutine.yield (block)
			end
		until not block
		f:close ()
	end

	return coroutine.wrap (gen)
end

function resource:addContentData (b)
	local f = assert (io.open (self.diskpath, "a+b"))
	f:seek ("end")
	f:write (b)
	f:close ()
end

function resource:delete ()
	local ok, err = os.remove (self.diskpath)
	if not ok then
		err = string.format ([[HTTP/1.1 424 %s]], err)
	end
	return ok, err
end

function resource:getItems (depth)
	local gen
	local path = self.path
	local diskpath = self.diskpath
	local rootdir = self.source.rootDir

	if depth == "0" then
		gen = function () coroutine.yield (self) end

	elseif depth == "1" then
		gen = function ()
				if self.attr.mode == "directory" then
					if string.sub (diskpath, -1) ~= "/" then
						diskpath = diskpath .."/"
					end
					if string.sub (path, -1) ~= "/" then
						path = path .."/"
					end
					for entry in lfs.dir (diskpath) do
						if string.sub (entry, 1,1) ~= "." then
							coroutine.yield (self.source:getResource (self.pfx, path..entry))
						end
					end
				end
				coroutine.yield (self)
			end

	else
		local function recur (p)
			local attr = assert (lfs.attributes (rootdir .. p))
			if attr.mode == "directory" then
				for entry in lfs.dir (rootdir .. p) do
					if string.sub (entry, 1,1) ~= "." then
						recur (p.."/"..entry)
					end
				end
			coroutine.yield (self.source:getResource (self.pfx, p))
			end
		end
		gen = function () recur (path) end
	end
	
	if gen then return coroutine.wrap (gen) end
end

function resource:getPath ()
	return self.path
end

function resource:getHRef ()
	local _,_,sfx = string.find (self.path, "^/*(.*)$")
	return self.pfx..sfx
end

function resource:getPropNames ()
	return pairs (_liveprops)
end

function resource:getProp (propname)
	local liveprop = _liveprops [propname]
	if liveprop then
		return liveprop (self)
	end
end

function resource:setProp (propname, value)
	return false
end

local M = {}

function M.makeSource (params)
	params = params or {}
	params.rootDir = params.rootDir or "."

	return setmetatable (params, source_mt)
end

return M

