import std/[
  os, osproc,
  strutils
]


proc runGitCommandAt(atPath: string, args: openArray[string]): string {.inline.} =
  osproc.execProcess(
    command = "git",
    workingDir = atPath,
    args = args,
    options = { poUsePath }
  ).strip()


proc gitRemoteGetUrl(atPath: string, remote: string): string {.inline.} =
  atPath.runGitCommandAt(["remote", "get-url", remote])

proc gitRevParseHead(atPath: string): string {.inline.} =
  atPath.runGitCommandAt(["rev-parse", "HEAD"])


type
  GitInfo = object
    url: string
    rev: string
    name: string
  DepInfo = object
    gitInfo: GitInfo
    srcDir: string # realistically either empty or "src"

proc grabGitInfo(atPath: string): GitInfo =
  result.url = atPath.gitRemoteGetUrl("origin")
  if result.url.endsWith(".git"):
    result.url = result.url[0 ..< result.url.len() - ".git".len()]
  result.rev = atPath.gitRevParseHead()
  result.name = result.url.splitPath().tail


const
  atlasSectionStart = "############# begin Atlas config section ##########"
  atlasSectionEnd = "############# end Atlas config section   ##########"
proc findProjectDeps(projectPath: string): seq[DepInfo] =
  let
    nimCfgContents = readFile(projectPath.joinPath("nim.cfg"))
    atlasStart = nimCfgContents.find(atlasSectionStart) + atlasSectionStart.len()
    atlasEnd = nimCfgContents.find(atlasSectionEnd)
    atlasSlice = nimCfgContents[atlasStart ..< atlasEnd].strip()
  for line in atlasSlice.splitLines():
    if not line.startsWith("--path:"):
      continue
    let
      depPath = line["--path:".len() .. ^1].strip(chars = {'"'})
      srcPath = projectPath.splitPath().head.joinPath(depPath)
      relPath = srcPath.rsplit("/src")[0]

    let
      gitInfo = relPath.grabGitInfo()
      srcDir = block:
        let tmp = srcPath.splitPath().tail
        if tmp == gitInfo.name:
          ""
        else:
          tmp
    result.add DepInfo(
      gitInfo : gitInfo,
      srcDir : srcDir
    )


proc genFlakeData(deps: seq[DepInfo]): string =
  var
    curIndent = 0

  template withIndent(body) =
    curIndent += 2
    body
    curIndent -= 2

  template writeLine(data: string) =
    result.add(" ".repeat(curIndent) & data)

  template withBaseScope(body) =
    result.add("{\n")
    withIndent:
      body
    writeLine("}")

  template withScope(body) =
    withBaseScope:
      body
    result.add(";\n")

  template withAttr(name: string, body) =
    writeLine(name & " = ")
    withScope:
      body

  template setAttr(name: string, val) =
    var x = val
    when x is string:
      x = "\"" & x & "\""
    writeLine(name & " = " & $x & ";\n")

  template putGitSource(dep: GitInfo) =
    writeLine("src = fetchGit ")
    withScope:
      setAttr("url", dep.url)
      setAttr("rev", dep.rev)


  var nimPathArgs = ""
  for dep in deps:
    nimPathArgs.add("--path:\\\"${" & dep.gitInfo.name & ".src}")
    if dep.srcDir.len() > 0:
      nimPathArgs.add("/" & dep.srcDir)
    nimPathArgs.add("\\\" ")
  nimPathArgs = nimPathArgs.strip()

  result &= "{ ... }:\nrec "
  withBaseScope:
    for dep in deps:
      withAttr(dep.gitInfo.name):
        setAttr("pname", dep.gitInfo.name)
        setAttr("version", dep.gitInfo.rev)
        putGitSource(dep.gitInfo)
    setAttr("nimPathArgs", nimPathArgs)


proc main() =
  let projectPath = paramStr(1)
  echo genFlakeData(findProjectDeps(projectPath))


when isMainModule:
  main()
