#
#
#           The Nim Compiler
#        (c) Copyright 2013 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# this module contains routines for accessing and iterating over types

import
  intsets, ast, astalgo, trees, msgs, strutils, platform, renderer, options,
  lineinfos

type
  TPreferedDesc* = enum
    preferName, preferDesc, preferExported, preferModuleInfo, preferGenericArg,
    preferTypeName

proc typeToString*(typ: PType; prefer: TPreferedDesc = preferName): string
template `$`*(typ: PType): string = typeToString(typ)

proc base*(t: PType): PType =
  result = t.sons[0]

# ------------------- type iterator: ----------------------------------------
type
  TTypeIter* = proc (t: PType, closure: RootRef): bool {.nimcall.} # true if iteration should stop
  TTypeMutator* = proc (t: PType, closure: RootRef): PType {.nimcall.} # copy t and mutate it
  TTypePredicate* = proc (t: PType): bool {.nimcall.}

proc iterOverType*(t: PType, iter: TTypeIter, closure: RootRef): bool
  # Returns result of `iter`.
proc mutateType*(t: PType, iter: TTypeMutator, closure: RootRef): PType
  # Returns result of `iter`.

type
  TParamsEquality* = enum     # they are equal, but their
                              # identifiers or their return
                              # type differ (i.e. they cannot be
                              # overloaded)
                              # this used to provide better error messages
    paramsNotEqual,           # parameters are not equal
    paramsEqual,              # parameters are equal
    paramsIncompatible

proc equalParams*(a, b: PNode): TParamsEquality
  # returns whether the parameter lists of the procs a, b are exactly the same

const
  # TODO: Remove tyTypeDesc from each abstractX and (where necessary)
  # replace with typedescX
  abstractPtrs* = {tyVar, tyPtr, tyRef, tyGenericInst, tyDistinct, tyOrdinal,
                   tyTypeDesc, tyAlias, tyInferred, tySink, tyLent, tyOwned}
  abstractVar* = {tyVar, tyGenericInst, tyDistinct, tyOrdinal, tyTypeDesc,
                  tyAlias, tyInferred, tySink, tyLent, tyOwned}
  abstractRange* = {tyGenericInst, tyRange, tyDistinct, tyOrdinal, tyTypeDesc,
                    tyAlias, tyInferred, tySink, tyOwned}
  abstractVarRange* = {tyGenericInst, tyRange, tyVar, tyDistinct, tyOrdinal,
                       tyTypeDesc, tyAlias, tyInferred, tySink, tyOwned}
  abstractInst* = {tyGenericInst, tyDistinct, tyOrdinal, tyTypeDesc, tyAlias,
                   tyInferred, tySink, tyOwned}
  abstractInstOwned* = abstractInst + {tyOwned}
  skipPtrs* = {tyVar, tyPtr, tyRef, tyGenericInst, tyTypeDesc, tyAlias,
               tyInferred, tySink, tyLent, tyOwned}
  # typedescX is used if we're sure tyTypeDesc should be included (or skipped)
  typedescPtrs* = abstractPtrs + {tyTypeDesc}
  typedescInst* = abstractInst + {tyTypeDesc, tyOwned}

proc invalidGenericInst*(f: PType): bool =
  result = f.kind == tyGenericInst and lastSon(f) == nil

proc isPureObject*(typ: PType): bool =
  var t = typ
  while t.kind == tyObject and t.sons[0] != nil:
    t = t.sons[0].skipTypes(skipPtrs)
  result = t.sym != nil and sfPure in t.sym.flags

proc getOrdValue*(n: PNode): BiggestInt =
  case n.kind
  of nkCharLit..nkUInt64Lit: n.intVal
  of nkNilLit: 0
  of nkHiddenStdConv: getOrdValue(n.sons[1])
  else: high(BiggestInt)

proc getFloatValue*(n: PNode): BiggestFloat =
  case n.kind
  of nkFloatLiterals: n.floatVal
  of nkHiddenStdConv: getFloatValue(n.sons[1])
  else: NaN

proc isIntLit*(t: PType): bool {.inline.} =
  result = t.kind == tyInt and t.n != nil and t.n.kind == nkIntLit

proc isFloatLit*(t: PType): bool {.inline.} =
  result = t.kind == tyFloat and t.n != nil and t.n.kind == nkFloatLit

proc getProcHeader*(conf: ConfigRef; sym: PSym; prefer: TPreferedDesc = preferName): string =
  assert sym != nil
  result = sym.owner.name.s & '.' & sym.name.s
  if sym.kind in routineKinds:
    result.add '('
    var n = sym.typ.n
    for i in 1 ..< sonsLen(n):
      let p = n.sons[i]
      if p.kind == nkSym:
        add(result, p.sym.name.s)
        add(result, ": ")
        add(result, typeToString(p.sym.typ, prefer))
        if i != sonsLen(n)-1: add(result, ", ")
      else:
        result.add renderTree(p)
    add(result, ')')
    if n.sons[0].typ != nil:
      result.add(": " & typeToString(n.sons[0].typ, prefer))
  result.add " [declared in "
  result.add(conf$sym.info)
  result.add "]"

proc elemType*(t: PType): PType =
  assert(t != nil)
  case t.kind
  of tyGenericInst, tyDistinct, tyAlias, tySink: result = elemType(lastSon(t))
  of tyArray: result = t.sons[1]
  of tyError: result = t
  else: result = t.lastSon
  assert(result != nil)

proc enumHasHoles*(t: PType): bool =
  var b = t.skipTypes({tyRange, tyGenericInst, tyAlias, tySink})
  result = b.kind == tyEnum and tfEnumHasHoles in b.flags

proc isOrdinalType*(t: PType, allowEnumWithHoles = false): bool =
  assert(t != nil)
  const
    # caution: uint, uint64 are no ordinal types!
    baseKinds = {tyChar,tyInt..tyInt64,tyUInt8..tyUInt32,tyBool,tyEnum}
    parentKinds = {tyRange, tyOrdinal, tyGenericInst, tyAlias, tySink, tyDistinct}
  (t.kind in baseKinds and not (t.enumHasHoles and not allowEnumWithHoles)) or
    (t.kind in parentKinds and isOrdinalType(t.lastSon))

proc iterOverTypeAux(marker: var IntSet, t: PType, iter: TTypeIter,
                     closure: RootRef): bool
proc iterOverNode(marker: var IntSet, n: PNode, iter: TTypeIter,
                  closure: RootRef): bool =
  if n != nil:
    case n.kind
    of nkNone..nkNilLit:
      # a leaf
      result = iterOverTypeAux(marker, n.typ, iter, closure)
    else:
      for i in 0 ..< sonsLen(n):
        result = iterOverNode(marker, n.sons[i], iter, closure)
        if result: return

proc iterOverTypeAux(marker: var IntSet, t: PType, iter: TTypeIter,
                     closure: RootRef): bool =
  result = false
  if t == nil: return
  result = iter(t, closure)
  if result: return
  if not containsOrIncl(marker, t.id):
    case t.kind
    of tyGenericInst, tyGenericBody, tyAlias, tySink, tyInferred:
      result = iterOverTypeAux(marker, lastSon(t), iter, closure)
    else:
      for i in 0 ..< sonsLen(t):
        result = iterOverTypeAux(marker, t.sons[i], iter, closure)
        if result: return
      if t.n != nil and t.kind != tyProc: result = iterOverNode(marker, t.n, iter, closure)

proc iterOverType(t: PType, iter: TTypeIter, closure: RootRef): bool =
  var marker = initIntSet()
  result = iterOverTypeAux(marker, t, iter, closure)

proc searchTypeForAux(t: PType, predicate: TTypePredicate,
                      marker: var IntSet): bool

proc searchTypeNodeForAux(n: PNode, p: TTypePredicate,
                          marker: var IntSet): bool =
  result = false
  case n.kind
  of nkRecList:
    for i in 0 ..< sonsLen(n):
      result = searchTypeNodeForAux(n.sons[i], p, marker)
      if result: return
  of nkRecCase:
    assert(n.sons[0].kind == nkSym)
    result = searchTypeNodeForAux(n.sons[0], p, marker)
    if result: return
    for i in 1 ..< sonsLen(n):
      case n.sons[i].kind
      of nkOfBranch, nkElse:
        result = searchTypeNodeForAux(lastSon(n.sons[i]), p, marker)
        if result: return
      else: discard
  of nkSym:
    result = searchTypeForAux(n.sym.typ, p, marker)
  else: discard

proc searchTypeForAux(t: PType, predicate: TTypePredicate,
                      marker: var IntSet): bool =
  # iterates over VALUE types!
  result = false
  if t == nil: return
  if containsOrIncl(marker, t.id): return
  result = predicate(t)
  if result: return
  case t.kind
  of tyObject:
    if t.sons[0] != nil:
      result = searchTypeForAux(t.sons[0].skipTypes(skipPtrs), predicate, marker)
    if not result: result = searchTypeNodeForAux(t.n, predicate, marker)
  of tyGenericInst, tyDistinct, tyAlias, tySink:
    result = searchTypeForAux(lastSon(t), predicate, marker)
  of tyArray, tySet, tyTuple:
    for i in 0 ..< sonsLen(t):
      result = searchTypeForAux(t.sons[i], predicate, marker)
      if result: return
  else:
    discard

proc searchTypeFor(t: PType, predicate: TTypePredicate): bool =
  var marker = initIntSet()
  result = searchTypeForAux(t, predicate, marker)

proc isObjectPredicate(t: PType): bool =
  result = t.kind == tyObject

proc containsObject*(t: PType): bool =
  result = searchTypeFor(t, isObjectPredicate)

proc isObjectWithTypeFieldPredicate(t: PType): bool =
  result = t.kind == tyObject and t.sons[0] == nil and
      not (t.sym != nil and {sfPure, sfInfixCall} * t.sym.flags != {}) and
      tfFinal notin t.flags

type
  TTypeFieldResult* = enum
    frNone,                   # type has no object type field
    frHeader,                 # type has an object type field only in the header
    frEmbedded                # type has an object type field somewhere embedded

proc analyseObjectWithTypeFieldAux(t: PType,
                                   marker: var IntSet): TTypeFieldResult =
  var res: TTypeFieldResult
  result = frNone
  if t == nil: return
  case t.kind
  of tyObject:
    if t.n != nil:
      if searchTypeNodeForAux(t.n, isObjectWithTypeFieldPredicate, marker):
        return frEmbedded
    for i in 0 ..< sonsLen(t):
      var x = t.sons[i]
      if x != nil: x = x.skipTypes(skipPtrs)
      res = analyseObjectWithTypeFieldAux(x, marker)
      if res == frEmbedded:
        return frEmbedded
      if res == frHeader: result = frHeader
    if result == frNone:
      if isObjectWithTypeFieldPredicate(t): result = frHeader
  of tyGenericInst, tyDistinct, tyAlias, tySink:
    result = analyseObjectWithTypeFieldAux(lastSon(t), marker)
  of tyArray, tyTuple:
    for i in 0 ..< sonsLen(t):
      res = analyseObjectWithTypeFieldAux(t.sons[i], marker)
      if res != frNone:
        return frEmbedded
  else:
    discard

proc analyseObjectWithTypeField*(t: PType): TTypeFieldResult =
  # this does a complex analysis whether a call to ``objectInit`` needs to be
  # made or intializing of the type field suffices or if there is no type field
  # at all in this type.
  var marker = initIntSet()
  result = analyseObjectWithTypeFieldAux(t, marker)

proc isGCRef(t: PType): bool =
  result = t.kind in GcTypeKinds or
    (t.kind == tyProc and t.callConv == ccClosure)
  if result and t.kind in {tyString, tySequence} and tfHasAsgn in t.flags:
    result = false

proc containsGarbageCollectedRef*(typ: PType): bool =
  # returns true if typ contains a reference, sequence or string (all the
  # things that are garbage-collected)
  result = searchTypeFor(typ, isGCRef)

proc isTyRef(t: PType): bool =
  result = t.kind == tyRef or (t.kind == tyProc and t.callConv == ccClosure)

proc containsTyRef*(typ: PType): bool =
  # returns true if typ contains a 'ref'
  result = searchTypeFor(typ, isTyRef)

proc isHiddenPointer(t: PType): bool =
  result = t.kind in {tyString, tySequence}

proc containsHiddenPointer*(typ: PType): bool =
  # returns true if typ contains a string, table or sequence (all the things
  # that need to be copied deeply)
  result = searchTypeFor(typ, isHiddenPointer)

proc canFormAcycleAux(marker: var IntSet, typ: PType, startId: int): bool
proc canFormAcycleNode(marker: var IntSet, n: PNode, startId: int): bool =
  result = false
  if n != nil:
    result = canFormAcycleAux(marker, n.typ, startId)
    if not result:
      case n.kind
      of nkNone..nkNilLit:
        discard
      else:
        for i in 0 ..< sonsLen(n):
          result = canFormAcycleNode(marker, n.sons[i], startId)
          if result: return

proc canFormAcycleAux(marker: var IntSet, typ: PType, startId: int): bool =
  result = false
  if typ == nil: return
  var t = skipTypes(typ, abstractInst+{tyOwned}-{tyTypeDesc})
  case t.kind
  of tyTuple, tyObject, tyRef, tySequence, tyArray, tyOpenArray, tyVarargs:
    if not containsOrIncl(marker, t.id):
      for i in 0 ..< sonsLen(t):
        result = canFormAcycleAux(marker, t.sons[i], startId)
        if result: return
      if t.n != nil: result = canFormAcycleNode(marker, t.n, startId)
    else:
      result = t.id == startId
    # Inheritance can introduce cyclic types, however this is not relevant
    # as the type that is passed to 'new' is statically known!
    # er but we use it also for the write barrier ...
    if t.kind == tyObject and tfFinal notin t.flags:
      # damn inheritance may introduce cycles:
      result = true
  of tyProc: result = typ.callConv == ccClosure
  else: discard

proc isFinal*(t: PType): bool =
  var t = t.skipTypes(abstractInst)
  result = t.kind != tyObject or tfFinal in t.flags

proc canFormAcycle*(typ: PType): bool =
  var marker = initIntSet()
  result = canFormAcycleAux(marker, typ, typ.id)

proc mutateTypeAux(marker: var IntSet, t: PType, iter: TTypeMutator,
                   closure: RootRef): PType
proc mutateNode(marker: var IntSet, n: PNode, iter: TTypeMutator,
                closure: RootRef): PNode =
  result = nil
  if n != nil:
    result = copyNode(n)
    result.typ = mutateTypeAux(marker, n.typ, iter, closure)
    case n.kind
    of nkNone..nkNilLit:
      # a leaf
      discard
    else:
      for i in 0 ..< sonsLen(n):
        addSon(result, mutateNode(marker, n.sons[i], iter, closure))

proc mutateTypeAux(marker: var IntSet, t: PType, iter: TTypeMutator,
                   closure: RootRef): PType =
  result = nil
  if t == nil: return
  result = iter(t, closure)
  if not containsOrIncl(marker, t.id):
    for i in 0 ..< sonsLen(t):
      result.sons[i] = mutateTypeAux(marker, result.sons[i], iter, closure)
    if t.n != nil: result.n = mutateNode(marker, t.n, iter, closure)
  assert(result != nil)

proc mutateType(t: PType, iter: TTypeMutator, closure: RootRef): PType =
  var marker = initIntSet()
  result = mutateTypeAux(marker, t, iter, closure)

proc valueToString(a: PNode): string =
  case a.kind
  of nkCharLit..nkUInt64Lit: result = $a.intVal
  of nkFloatLit..nkFloat128Lit: result = $a.floatVal
  of nkStrLit..nkTripleStrLit: result = a.strVal
  else: result = "<invalid value>"

proc rangeToStr(n: PNode): string =
  assert(n.kind == nkRange)
  result = valueToString(n.sons[0]) & ".." & valueToString(n.sons[1])

const
  typeToStr: array[TTypeKind, string] = ["None", "bool", "Char", "empty",
    "Alias", "nil", "untyped", "typed", "typeDesc",
    "GenericInvocation", "GenericBody", "GenericInst", "GenericParam",
    "distinct $1", "enum", "ordinal[$1]", "array[$1, $2]", "object", "tuple",
    "set[$1]", "range[$1]", "ptr ", "ref ", "var ", "seq[$1]", "proc",
    "pointer", "OpenArray[$1]", "string", "CString", "Forward",
    "int", "int8", "int16", "int32", "int64",
    "float", "float32", "float64", "float128",
    "uint", "uint8", "uint16", "uint32", "uint64",
    "owned", "sink",
    "lent ", "varargs[$1]", "UncheckedArray[$1]", "Error Type",
    "BuiltInTypeClass", "UserTypeClass",
    "UserTypeClassInst", "CompositeTypeClass", "inferred",
    "and", "or", "not", "any", "static", "TypeFromExpr", "FieldAccessor",
    "void"]

const preferToResolveSymbols = {preferName, preferTypeName, preferModuleInfo, preferGenericArg}

template bindConcreteTypeToUserTypeClass*(tc, concrete: PType) =
  tc.sons.add concrete
  tc.flags.incl tfResolved

# TODO: It would be a good idea to kill the special state of a resolved
# concept by switching to tyAlias within the instantiated procs.
# Currently, tyAlias is always skipped with lastSon, which means that
# we can store information about the matched concept in another position.
# Then builtInFieldAccess can be modified to properly read the derived
# consts and types stored within the concept.
template isResolvedUserTypeClass*(t: PType): bool =
  tfResolved in t.flags

proc addTypeFlags(name: var string, typ: PType) {.inline.} =
  if tfNotNil in typ.flags: name.add(" not nil")

proc typeToString(typ: PType, prefer: TPreferedDesc = preferName): string =
  var t = typ
  result = ""
  if t == nil: return
  if prefer in preferToResolveSymbols and t.sym != nil and
       sfAnon notin t.sym.flags and t.kind != tySequence:
    if t.kind == tyInt and isIntLit(t):
      result = t.sym.name.s & " literal(" & $t.n.intVal & ")"
    elif t.kind == tyAlias and t.sons[0].kind != tyAlias:
      result = typeToString(t.sons[0])
    elif prefer in {preferName, preferTypeName} or t.sym.owner.isNil:
      result = t.sym.name.s
      if t.kind == tyGenericParam and t.sonsLen > 0:
        result.add ": "
        var first = true
        for son in t.sons:
          if not first: result.add " or "
          result.add son.typeToString
          first = false
    else:
      result = t.sym.owner.name.s & '.' & t.sym.name.s
    result.addTypeFlags(t)
    return
  case t.kind
  of tyInt:
    if not isIntLit(t) or prefer == preferExported:
      result = typeToStr[t.kind]
    else:
      if prefer == preferGenericArg:
        result = $t.n.intVal
      else:
        result = "int literal(" & $t.n.intVal & ")"
  of tyGenericInst, tyGenericInvocation:
    result = typeToString(t.sons[0]) & '['
    for i in 1 ..< sonsLen(t)-ord(t.kind != tyGenericInvocation):
      if i > 1: add(result, ", ")
      add(result, typeToString(t.sons[i], preferGenericArg))
    add(result, ']')
  of tyGenericBody:
    result = typeToString(t.lastSon) & '['
    for i in 0 .. sonsLen(t)-2:
      if i > 0: add(result, ", ")
      add(result, typeToString(t.sons[i], preferTypeName))
    add(result, ']')
  of tyTypeDesc:
    if t.sons[0].kind == tyNone: result = "typedesc"
    else: result = "type " & typeToString(t.sons[0])
  of tyStatic:
    if prefer == preferGenericArg and t.n != nil:
      result = t.n.renderTree
    else:
      result = "static[" & (if t.len > 0: typeToString(t.sons[0]) else: "") & "]"
      if t.n != nil: result.add "(" & renderTree(t.n) & ")"
  of tyUserTypeClass:
    if t.sym != nil and t.sym.owner != nil:
      if t.isResolvedUserTypeClass: return typeToString(t.lastSon)
      return t.sym.owner.name.s
    else:
      result = "<invalid tyUserTypeClass>"
  of tyBuiltInTypeClass:
    result = case t.base.kind:
      of tyVar: "var"
      of tyRef: "ref"
      of tyPtr: "ptr"
      of tySequence: "seq"
      of tyArray: "array"
      of tySet: "set"
      of tyRange: "range"
      of tyDistinct: "distinct"
      of tyProc: "proc"
      of tyObject: "object"
      of tyTuple: "tuple"
      of tyOpenArray: "openarray"
      else: typeToStr[t.base.kind]
  of tyInferred:
    let concrete = t.previouslyInferred
    if concrete != nil: result = typeToString(concrete)
    else: result = "inferred[" & typeToString(t.base) & "]"
  of tyUserTypeClassInst:
    let body = t.base
    result = body.sym.name.s & "["
    for i in 1 .. sonsLen(t) - 2:
      if i > 1: add(result, ", ")
      add(result, typeToString(t.sons[i]))
    result.add "]"
  of tyAnd:
    for i, son in t.sons:
      result.add(typeToString(son))
      if i < t.sons.high:
        result.add(" and ")
  of tyOr:
    for i, son in t.sons:
      result.add(typeToString(son))
      if i < t.sons.high:
        result.add(" or ")
  of tyNot:
    result = "not " & typeToString(t.sons[0])
  of tyUntyped:
    #internalAssert t.len == 0
    result = "untyped"
  of tyFromExpr:
    if t.n == nil:
      result = "unknown"
    else:
      result = "type(" & renderTree(t.n) & ")"
  of tyArray:
    if t.sons[0].kind == tyRange:
      result = "array[" & rangeToStr(t.sons[0].n) & ", " &
          typeToString(t.sons[1]) & ']'
    else:
      result = "array[" & typeToString(t.sons[0]) & ", " &
          typeToString(t.sons[1]) & ']'
  of tyUncheckedArray:
    result = "UncheckedArray[" & typeToString(t.sons[0]) & ']'
  of tySequence:
    result = "seq[" & typeToString(t.sons[0]) & ']'
  of tyOpt:
    result = "opt[" & typeToString(t.sons[0]) & ']'
  of tyOrdinal:
    result = "ordinal[" & typeToString(t.sons[0]) & ']'
  of tySet:
    result = "set[" & typeToString(t.sons[0]) & ']'
  of tyOpenArray:
    result = "openarray[" & typeToString(t.sons[0]) & ']'
  of tyDistinct:
    result = "distinct " & typeToString(t.sons[0],
      if prefer == preferModuleInfo: preferModuleInfo else: preferTypeName)
  of tyTuple:
    # we iterate over t.sons here, because t.n may be nil
    if t.n != nil:
      result = "tuple["
      assert(sonsLen(t.n) == sonsLen(t))
      for i in 0 ..< sonsLen(t.n):
        assert(t.n.sons[i].kind == nkSym)
        add(result, t.n.sons[i].sym.name.s & ": " & typeToString(t.sons[i]))
        if i < sonsLen(t.n) - 1: add(result, ", ")
      add(result, ']')
    elif sonsLen(t) == 0:
      result = "tuple[]"
    else:
      if prefer == preferTypeName: result = "("
      else: result = "tuple of ("
      for i in 0 ..< sonsLen(t):
        add(result, typeToString(t.sons[i]))
        if i < sonsLen(t) - 1: add(result, ", ")
      add(result, ')')
  of tyPtr, tyRef, tyVar, tyLent:
    result = typeToStr[t.kind]
    if t.len >= 2:
      setLen(result, result.len-1)
      result.add '['
      for i in 0 ..< sonsLen(t):
        add(result, typeToString(t.sons[i]))
        if i < sonsLen(t) - 1: add(result, ", ")
      result.add ']'
    else:
      result.add typeToString(t.sons[0])
  of tyRange:
    result = "range "
    if t.n != nil and t.n.kind == nkRange:
      result.add rangeToStr(t.n)
    if prefer != preferExported:
      result.add("(" & typeToString(t.sons[0]) & ")")
  of tyProc:
    result = if tfIterator in t.flags: "iterator "
             elif t.owner != nil:
               case t.owner.kind
               of skTemplate: "template "
               of skMacro: "macro "
               of skConverter: "converter "
               else: "proc "
            else:
              "proc "
    if tfUnresolved in t.flags: result.add "[*missing parameters*]"
    result.add "("
    for i in 1 ..< sonsLen(t):
      if t.n != nil and i < t.n.len and t.n[i].kind == nkSym:
        add(result, t.n[i].sym.name.s)
        add(result, ": ")
      add(result, typeToString(t.sons[i]))
      if i < sonsLen(t) - 1: add(result, ", ")
    add(result, ')')
    if t.len > 0 and t.sons[0] != nil: add(result, ": " & typeToString(t.sons[0]))
    var prag = if t.callConv == ccDefault: "" else: CallingConvToStr[t.callConv]
    if tfNoSideEffect in t.flags:
      addSep(prag)
      add(prag, "noSideEffect")
    if tfThread in t.flags:
      addSep(prag)
      add(prag, "gcsafe")
    if t.lockLevel.ord != UnspecifiedLockLevel.ord:
      addSep(prag)
      add(prag, "locks: " & $t.lockLevel)
    if len(prag) != 0: add(result, "{." & prag & ".}")
  of tyVarargs:
    result = typeToStr[t.kind] % typeToString(t.sons[0])
  of tySink:
    result = "sink " & typeToString(t.sons[0])
  of tyOwned:
    result = "owned " & typeToString(t.sons[0])
  else:
    result = typeToStr[t.kind]
  result.addTypeFlags(t)

proc firstOrd*(conf: ConfigRef; t: PType): BiggestInt =
  case t.kind
  of tyBool, tyChar, tySequence, tyOpenArray, tyString, tyVarargs, tyProxy:
    result = 0
  of tySet, tyVar: result = firstOrd(conf, t.sons[0])
  of tyArray: result = firstOrd(conf, t.sons[0])
  of tyRange:
    assert(t.n != nil)        # range directly given:
    assert(t.n.kind == nkRange)
    result = getOrdValue(t.n.sons[0])
  of tyInt:
    if conf != nil and conf.target.intSize == 4: result = - (2147483646) - 2
    else: result = 0x8000000000000000'i64
  of tyInt8: result = - 128
  of tyInt16: result = - 32768
  of tyInt32: result = - 2147483646 - 2
  of tyInt64: result = 0x8000000000000000'i64
  of tyUInt..tyUInt64: result = 0
  of tyEnum:
    # if basetype <> nil then return firstOrd of basetype
    if sonsLen(t) > 0 and t.sons[0] != nil:
      result = firstOrd(conf, t.sons[0])
    else:
      assert(t.n.sons[0].kind == nkSym)
      result = t.n.sons[0].sym.position
  of tyGenericInst, tyDistinct, tyTypeDesc, tyAlias, tySink,
     tyStatic, tyInferred, tyUserTypeClasses:
    result = firstOrd(conf, lastSon(t))
  of tyOrdinal:
    if t.len > 0: result = firstOrd(conf, lastSon(t))
    else: internalError(conf, "invalid kind for firstOrd(" & $t.kind & ')')
  of tyUncheckedArray:
    result = 0
  else:
    internalError(conf, "invalid kind for firstOrd(" & $t.kind & ')')
    result = 0


proc firstFloat*(t: PType): BiggestFloat =
  case t.kind
  of tyFloat..tyFloat128: -Inf
  of tyRange:
    assert(t.n != nil)        # range directly given:
    assert(t.n.kind == nkRange)
    getFloatValue(t.n.sons[0])
  of tyVar: firstFloat(t.sons[0])
  of tyGenericInst, tyDistinct, tyTypeDesc, tyAlias, tySink,
     tyStatic, tyInferred, tyUserTypeClasses:
    firstFloat(lastSon(t))
  else:
    internalError(newPartialConfigRef(), "invalid kind for firstFloat(" & $t.kind & ')')
    NaN

proc lastOrd*(conf: ConfigRef; t: PType; fixedUnsigned = false): BiggestInt =
  case t.kind
  of tyBool: result = 1
  of tyChar: result = 255
  of tySet, tyVar: result = lastOrd(conf, t.sons[0])
  of tyArray: result = lastOrd(conf, t.sons[0])
  of tyRange:
    assert(t.n != nil)        # range directly given:
    assert(t.n.kind == nkRange)
    result = getOrdValue(t.n.sons[1])
  of tyInt:
    if conf != nil and conf.target.intSize == 4: result = 0x7FFFFFFF
    else: result = 0x7FFFFFFFFFFFFFFF'i64
  of tyInt8: result = 0x0000007F
  of tyInt16: result = 0x00007FFF
  of tyInt32: result = 0x7FFFFFFF
  of tyInt64: result = 0x7FFFFFFFFFFFFFFF'i64
  of tyUInt:
    if conf != nil and conf.target.intSize == 4: result = 0xFFFFFFFF
    elif fixedUnsigned: result = 0xFFFFFFFFFFFFFFFF'i64
    else: result = 0x7FFFFFFFFFFFFFFF'i64
  of tyUInt8: result = 0xFF
  of tyUInt16: result = 0xFFFF
  of tyUInt32: result = 0xFFFFFFFF
  of tyUInt64:
    if fixedUnsigned: result = 0xFFFFFFFFFFFFFFFF'i64
    else: result = 0x7FFFFFFFFFFFFFFF'i64
  of tyEnum:
    assert(t.n.sons[sonsLen(t.n) - 1].kind == nkSym)
    result = t.n.sons[sonsLen(t.n) - 1].sym.position
  of tyGenericInst, tyDistinct, tyTypeDesc, tyAlias, tySink,
     tyStatic, tyInferred, tyUserTypeClasses:
    result = lastOrd(conf, lastSon(t))
  of tyProxy: result = 0
  of tyOrdinal:
    if t.len > 0: result = lastOrd(conf, lastSon(t))
    else: internalError(conf, "invalid kind for lastOrd(" & $t.kind & ')')
  of tyUncheckedArray:
    result = high(BiggestInt)
  else:
    internalError(conf, "invalid kind for lastOrd(" & $t.kind & ')')
    result = 0


proc lastFloat*(t: PType): BiggestFloat =
  case t.kind
  of tyFloat..tyFloat128: Inf
  of tyVar: lastFloat(t.sons[0])
  of tyRange:
    assert(t.n != nil)        # range directly given:
    assert(t.n.kind == nkRange)
    getFloatValue(t.n.sons[1])
  of tyGenericInst, tyDistinct, tyTypeDesc, tyAlias, tySink,
     tyStatic, tyInferred, tyUserTypeClasses:
    lastFloat(lastSon(t))
  else:
    internalError(newPartialConfigRef(), "invalid kind for lastFloat(" & $t.kind & ')')
    NaN

proc floatRangeCheck*(x: BiggestFloat, t: PType): bool =
  case t.kind
  # This needs to be special cased since NaN is never
  # part of firstFloat(t) .. lastFloat(t)
  of tyFloat..tyFloat128:
    true
  of tyRange:
    x in firstFloat(t) .. lastFloat(t)
  of tyVar:
    floatRangeCheck(x, t.sons[0])
  of tyGenericInst, tyDistinct, tyTypeDesc, tyAlias, tySink,
     tyStatic, tyInferred, tyUserTypeClasses:
    floatRangeCheck(x, lastSon(t))
  else:
    internalError(newPartialConfigRef(), "invalid kind for floatRangeCheck:" & $t.kind)
    false

proc lengthOrd*(conf: ConfigRef; t: PType): BiggestInt =
  case t.skipTypes(tyUserTypeClasses).kind
  of tyInt64, tyInt32, tyInt: result = lastOrd(conf, t)
  of tyDistinct: result = lengthOrd(conf, t.sons[0])
  else:
    let last = lastOrd(conf, t)
    let first = firstOrd(conf, t)
    # XXX use a better overflow check here:
    if last == high(BiggestInt) and first <= 0:
      result = last
    else:
      result = last - first + 1

# -------------- type equality -----------------------------------------------

type
  TDistinctCompare* = enum ## how distinct types are to be compared
    dcEq,                  ## a and b should be the same type
    dcEqIgnoreDistinct,    ## compare symmetrically: (distinct a) == b, a == b
                           ## or a == (distinct b)
    dcEqOrDistinctOf       ## a equals b or a is distinct of b

  TTypeCmpFlag* = enum
    IgnoreTupleFields      ## NOTE: Only set this flag for backends!
    IgnoreCC
    ExactTypeDescValues
    ExactGenericParams
    ExactConstraints
    ExactGcSafety
    AllowCommonBase

  TTypeCmpFlags* = set[TTypeCmpFlag]

  TSameTypeClosure = object
    cmp: TDistinctCompare
    recCheck: int
    flags: TTypeCmpFlags
    s: seq[tuple[a,b: int]] # seq for a set as it's hopefully faster
                            # (few elements expected)

proc initSameTypeClosure: TSameTypeClosure =
  # we do the initialization lazily for performance (avoids memory allocations)
  discard

proc containsOrIncl(c: var TSameTypeClosure, a, b: PType): bool =
  result = c.s.len > 0 and c.s.contains((a.id, b.id))
  if not result:
    when not defined(nimNoNilSeqs):
      if isNil(c.s): c.s = @[]
    c.s.add((a.id, b.id))

proc sameTypeAux(x, y: PType, c: var TSameTypeClosure): bool
proc sameTypeOrNilAux(a, b: PType, c: var TSameTypeClosure): bool =
  if a == b:
    result = true
  else:
    if a == nil or b == nil: result = false
    else: result = sameTypeAux(a, b, c)

proc sameType*(a, b: PType, flags: TTypeCmpFlags = {}): bool =
  var c = initSameTypeClosure()
  c.flags = flags
  result = sameTypeAux(a, b, c)

proc sameTypeOrNil*(a, b: PType, flags: TTypeCmpFlags = {}): bool =
  if a == b:
    result = true
  else:
    if a == nil or b == nil: result = false
    else: result = sameType(a, b, flags)

proc equalParam(a, b: PSym): TParamsEquality =
  if sameTypeOrNil(a.typ, b.typ, {ExactTypeDescValues}) and
      exprStructuralEquivalent(a.constraint, b.constraint):
    if a.ast == b.ast:
      result = paramsEqual
    elif a.ast != nil and b.ast != nil:
      if exprStructuralEquivalent(a.ast, b.ast): result = paramsEqual
      else: result = paramsIncompatible
    elif a.ast != nil:
      result = paramsEqual
    elif b.ast != nil:
      result = paramsIncompatible
  else:
    result = paramsNotEqual

proc sameConstraints(a, b: PNode): bool =
  if isNil(a) and isNil(b): return true
  if a.len != b.len: return false
  for i in 1 ..< a.len:
    if not exprStructuralEquivalent(a[i].sym.constraint,
                                    b[i].sym.constraint):
      return false
  return true

proc equalParams(a, b: PNode): TParamsEquality =
  result = paramsEqual
  var length = sonsLen(a)
  if length != sonsLen(b):
    result = paramsNotEqual
  else:
    for i in 1 ..< length:
      var m = a.sons[i].sym
      var n = b.sons[i].sym
      assert((m.kind == skParam) and (n.kind == skParam))
      case equalParam(m, n)
      of paramsNotEqual:
        return paramsNotEqual
      of paramsEqual:
        discard
      of paramsIncompatible:
        result = paramsIncompatible
      if (m.name.id != n.name.id):
        # BUGFIX
        return paramsNotEqual # paramsIncompatible;
      # continue traversal! If not equal, we can return immediately; else
      # it stays incompatible
    if not sameTypeOrNil(a.typ, b.typ, {ExactTypeDescValues}):
      if (a.typ == nil) or (b.typ == nil):
        result = paramsNotEqual # one proc has a result, the other not is OK
      else:
        result = paramsIncompatible # overloading by different
                                    # result types does not work

proc sameTuple(a, b: PType, c: var TSameTypeClosure): bool =
  # two tuples are equivalent iff the names, types and positions are the same;
  # however, both types may not have any field names (t.n may be nil) which
  # complicates the matter a bit.
  if sonsLen(a) == sonsLen(b):
    result = true
    for i in 0 ..< sonsLen(a):
      var x = a.sons[i]
      var y = b.sons[i]
      if IgnoreTupleFields in c.flags:
        x = skipTypes(x, {tyRange, tyGenericInst, tyAlias})
        y = skipTypes(y, {tyRange, tyGenericInst, tyAlias})

      result = sameTypeAux(x, y, c)
      if not result: return
    if a.n != nil and b.n != nil and IgnoreTupleFields notin c.flags:
      for i in 0 ..< sonsLen(a.n):
        # check field names:
        if a.n.sons[i].kind == nkSym and b.n.sons[i].kind == nkSym:
          var x = a.n.sons[i].sym
          var y = b.n.sons[i].sym
          result = x.name.id == y.name.id
          if not result: break
        else:
          return false
    elif a.n != b.n and (a.n == nil or b.n == nil) and IgnoreTupleFields notin c.flags:
      result = false

template ifFastObjectTypeCheckFailed(a, b: PType, body: untyped) =
  if tfFromGeneric notin a.flags + b.flags:
    # fast case: id comparison suffices:
    result = a.id == b.id
  else:
    # expensive structural equality test; however due to the way generic and
    # objects work, if one of the types does **not** contain tfFromGeneric,
    # they cannot be equal. The check ``a.sym.id == b.sym.id`` checks
    # for the same origin and is essential because we don't want "pure"
    # structural type equivalence:
    #
    # type
    #   TA[T] = object
    #   TB[T] = object
    # --> TA[int] != TB[int]
    if tfFromGeneric in a.flags * b.flags and a.sym.id == b.sym.id:
      # ok, we need the expensive structural check
      body

proc sameObjectTypes*(a, b: PType): bool =
  # specialized for efficiency (sigmatch uses it)
  ifFastObjectTypeCheckFailed(a, b):
    var c = initSameTypeClosure()
    result = sameTypeAux(a, b, c)

proc sameDistinctTypes*(a, b: PType): bool {.inline.} =
  result = sameObjectTypes(a, b)

proc sameEnumTypes*(a, b: PType): bool {.inline.} =
  result = a.id == b.id

proc sameObjectTree(a, b: PNode, c: var TSameTypeClosure): bool =
  if a == b:
    result = true
  elif a != nil and b != nil and a.kind == b.kind:
    var x = a.typ
    var y = b.typ
    if IgnoreTupleFields in c.flags:
      if x != nil: x = skipTypes(x, {tyRange, tyGenericInst, tyAlias})
      if y != nil: y = skipTypes(y, {tyRange, tyGenericInst, tyAlias})
    if sameTypeOrNilAux(x, y, c):
      case a.kind
      of nkSym:
        # same symbol as string is enough:
        result = a.sym.name.id == b.sym.name.id
      of nkIdent: result = a.ident.id == b.ident.id
      of nkCharLit..nkInt64Lit: result = a.intVal == b.intVal
      of nkFloatLit..nkFloat64Lit: result = a.floatVal == b.floatVal
      of nkStrLit..nkTripleStrLit: result = a.strVal == b.strVal
      of nkEmpty, nkNilLit, nkType: result = true
      else:
        if sonsLen(a) == sonsLen(b):
          for i in 0 ..< sonsLen(a):
            if not sameObjectTree(a.sons[i], b.sons[i], c): return
          result = true

proc sameObjectStructures(a, b: PType, c: var TSameTypeClosure): bool =
  # check base types:
  if sonsLen(a) != sonsLen(b): return
  for i in 0 ..< sonsLen(a):
    if not sameTypeOrNilAux(a.sons[i], b.sons[i], c): return
  if not sameObjectTree(a.n, b.n, c): return
  result = true

proc sameChildrenAux(a, b: PType, c: var TSameTypeClosure): bool =
  if sonsLen(a) != sonsLen(b): return false
  result = true
  for i in 0 ..< sonsLen(a):
    result = sameTypeOrNilAux(a.sons[i], b.sons[i], c)
    if not result: return

proc isGenericAlias*(t: PType): bool =
  return t.kind == tyGenericInst and t.lastSon.kind == tyGenericInst

proc skipGenericAlias*(t: PType): PType =
  return if t.isGenericAlias: t.lastSon else: t

proc sameFlags*(a, b: PType): bool {.inline.} =
  result = eqTypeFlags*a.flags == eqTypeFlags*b.flags

proc sameTypeAux(x, y: PType, c: var TSameTypeClosure): bool =
  template cycleCheck() =
    # believe it or not, the direct check for ``containsOrIncl(c, a, b)``
    # increases bootstrapping time from 2.4s to 3.3s on my laptop! So we cheat
    # again: Since the recursion check is only to not get caught in an endless
    # recursion, we use a counter and only if it's value is over some
    # threshold we perform the expensive exact cycle check:
    if c.recCheck < 3:
      inc c.recCheck
    else:
      if containsOrIncl(c, a, b): return true

  if x == y: return true
  var a = skipTypes(x, {tyGenericInst, tyAlias})
  var b = skipTypes(y, {tyGenericInst, tyAlias})
  assert(a != nil)
  assert(b != nil)
  if a.kind != b.kind:
    case c.cmp
    of dcEq: return false
    of dcEqIgnoreDistinct:
      while a.kind == tyDistinct: a = a.sons[0]
      while b.kind == tyDistinct: b = b.sons[0]
      if a.kind != b.kind: return false
    of dcEqOrDistinctOf:
      while a.kind == tyDistinct: a = a.sons[0]
      if a.kind != b.kind: return false

  # this is required by tunique_type but makes no sense really:
  if x.kind == tyGenericInst and IgnoreTupleFields notin c.flags:
    let
      lhs = x.skipGenericAlias
      rhs = y.skipGenericAlias
    if rhs.kind != tyGenericInst or lhs.base != rhs.base:
      return false
    for i in 1 .. lhs.len - 2:
      let ff = rhs.sons[i]
      let aa = lhs.sons[i]
      if not sameTypeAux(ff, aa, c): return false
    return true

  case a.kind
  of tyEmpty, tyChar, tyBool, tyNil, tyPointer, tyString, tyCString,
     tyInt..tyUInt64, tyTyped, tyUntyped, tyVoid:
    result = sameFlags(a, b)
  of tyStatic, tyFromExpr:
    result = exprStructuralEquivalent(a.n, b.n) and sameFlags(a, b)
    if result and a.len == b.len and a.len == 1:
      cycleCheck()
      result = sameTypeAux(a.sons[0], b.sons[0], c)
  of tyObject:
    ifFastObjectTypeCheckFailed(a, b):
      cycleCheck()
      result = sameObjectStructures(a, b, c) and sameFlags(a, b)
  of tyDistinct:
    cycleCheck()
    if c.cmp == dcEq:
      if sameFlags(a, b):
        ifFastObjectTypeCheckFailed(a, b):
          result = sameTypeAux(a.sons[0], b.sons[0], c)
    else:
      result = sameTypeAux(a.sons[0], b.sons[0], c) and sameFlags(a, b)
  of tyEnum, tyForward:
    # XXX generic enums do not make much sense, but require structural checking
    result = a.id == b.id and sameFlags(a, b)
  of tyError:
    result = b.kind == tyError
  of tyTuple:
    cycleCheck()
    result = sameTuple(a, b, c) and sameFlags(a, b)
  of tyTypeDesc:
    if c.cmp == dcEqIgnoreDistinct: result = false
    elif ExactTypeDescValues in c.flags:
      cycleCheck()
      result = sameChildrenAux(x, y, c) and sameFlags(a, b)
    else:
      result = sameFlags(a, b)
  of tyGenericParam:
    result = sameChildrenAux(a, b, c) and sameFlags(a, b)
    if result and {ExactGenericParams, ExactTypeDescValues} * c.flags != {}:
      result = a.sym.position == b.sym.position
  of tyGenericInvocation, tyGenericBody, tySequence,
     tyOpenArray, tySet, tyRef, tyPtr, tyVar, tyLent, tySink, tyUncheckedArray,
     tyArray, tyProc, tyVarargs, tyOrdinal, tyTypeClasses, tyOpt, tyOwned:
    cycleCheck()
    if a.kind == tyUserTypeClass and a.n != nil: return a.n == b.n
    result = sameChildrenAux(a, b, c)
    if result:
      if IgnoreTupleFields in c.flags:
        result = a.flags * {tfVarIsPtr} == b.flags * {tfVarIsPtr}
      else:
        result = sameFlags(a, b)
    if result and ExactGcSafety in c.flags:
      result = a.flags * {tfThread} == b.flags * {tfThread}
    if result and a.kind == tyProc:
      result = ((IgnoreCC in c.flags) or a.callConv == b.callConv) and
               ((ExactConstraints notin c.flags) or sameConstraints(a.n, b.n))
  of tyRange:
    cycleCheck()
    result = sameTypeOrNilAux(a.sons[0], b.sons[0], c) and
        sameValue(a.n.sons[0], b.n.sons[0]) and
        sameValue(a.n.sons[1], b.n.sons[1])
  of tyGenericInst, tyAlias, tyInferred:
    cycleCheck()
    result = sameTypeAux(a.lastSon, b.lastSon, c)
  of tyNone: result = false

proc sameBackendType*(x, y: PType): bool =
  var c = initSameTypeClosure()
  c.flags.incl IgnoreTupleFields
  c.cmp = dcEqIgnoreDistinct
  result = sameTypeAux(x, y, c)

proc compareTypes*(x, y: PType,
                   cmp: TDistinctCompare = dcEq,
                   flags: TTypeCmpFlags = {}): bool =
  ## compares two type for equality (modulo type distinction)
  var c = initSameTypeClosure()
  c.cmp = cmp
  c.flags = flags
  if x == y: result = true
  elif x.isNil or y.isNil: result = false
  else: result = sameTypeAux(x, y, c)

proc inheritanceDiff*(a, b: PType): int =
  # | returns: 0 iff `a` == `b`
  # | returns: -x iff `a` is the x'th direct superclass of `b`
  # | returns: +x iff `a` is the x'th direct subclass of `b`
  # | returns: `maxint` iff `a` and `b` are not compatible at all
  if a == b or a.kind == tyError or b.kind == tyError: return 0
  assert a.kind in {tyObject} + skipPtrs
  assert b.kind in {tyObject} + skipPtrs
  var x = a
  result = 0
  while x != nil:
    x = skipTypes(x, skipPtrs)
    if sameObjectTypes(x, b): return
    x = x.sons[0]
    dec(result)
  var y = b
  result = 0
  while y != nil:
    y = skipTypes(y, skipPtrs)
    if sameObjectTypes(y, a): return
    y = y.sons[0]
    inc(result)
  result = high(int)

proc commonSuperclass*(a, b: PType): PType =
  # quick check: are they the same?
  if sameObjectTypes(a, b): return a

  # simple algorithm: we store all ancestors of 'a' in a ID-set and walk 'b'
  # up until the ID is found:
  assert a.kind == tyObject
  assert b.kind == tyObject
  var x = a
  var ancestors = initIntSet()
  while x != nil:
    x = skipTypes(x, skipPtrs)
    ancestors.incl(x.id)
    x = x.sons[0]
  var y = b
  while y != nil:
    var t = y # bug #7818, save type before skip
    y = skipTypes(y, skipPtrs)
    if ancestors.contains(y.id):
      # bug #7818, defer the previous skipTypes
      if t.kind != tyGenericInst: t = y
      return t
    y = y.sons[0]

type
  TTypeAllowedFlag* = enum
    taField,
    taHeap,
    taConcept

  TTypeAllowedFlags* = set[TTypeAllowedFlag]

proc typeAllowedAux(marker: var IntSet, typ: PType, kind: TSymKind,
                    flags: TTypeAllowedFlags = {}): PType

proc typeAllowedNode(marker: var IntSet, n: PNode, kind: TSymKind,
                     flags: TTypeAllowedFlags = {}): PType =
  if n != nil:
    result = typeAllowedAux(marker, n.typ, kind, flags)
    if result == nil:
      case n.kind
      of nkNone..nkNilLit:
        discard
      else:
        if n.kind == nkRecCase and kind in {skProc, skFunc, skConst}:
          return n[0].typ
        for i in 0 ..< sonsLen(n):
          let it = n.sons[i]
          result = typeAllowedNode(marker, it, kind, flags)
          if result != nil: break

proc matchType*(a: PType, pattern: openArray[tuple[k:TTypeKind, i:int]],
                last: TTypeKind): bool =
  var a = a
  for k, i in pattern.items:
    if a.kind != k: return false
    if i >= a.sonsLen or a.sons[i] == nil: return false
    a = a.sons[i]
  result = a.kind == last

proc typeAllowedAux(marker: var IntSet, typ: PType, kind: TSymKind,
                    flags: TTypeAllowedFlags = {}): PType =
  assert(kind in {skVar, skLet, skConst, skProc, skFunc, skParam, skResult})
  # if we have already checked the type, return true, because we stop the
  # evaluation if something is wrong:
  result = nil
  if typ == nil: return nil
  if containsOrIncl(marker, typ.id): return nil
  var t = skipTypes(typ, abstractInst-{tyTypeDesc})
  case t.kind
  of tyVar, tyLent:
    if kind in {skProc, skFunc, skConst}:
      result = t
    elif t.kind == tyLent and kind != skResult:
      result = t
    else:
      var t2 = skipTypes(t.sons[0], abstractInst-{tyTypeDesc})
      case t2.kind
      of tyVar, tyLent:
        if taHeap notin flags: result = t2 # ``var var`` is illegal on the heap
      of tyOpenArray, tyUncheckedArray:
        if kind != skParam: result = t
        else: result = typeAllowedAux(marker, t2.sons[0], skParam, flags)
      else:
        if kind notin {skParam, skResult}: result = t
        else: result = typeAllowedAux(marker, t2, kind, flags)
  of tyProc:
    if kind == skConst and t.callConv == ccClosure:
      result = t
    else:
      for i in 1 ..< sonsLen(t):
        result = typeAllowedAux(marker, t.sons[i], skParam, flags)
        if result != nil: break
      if result.isNil and t.sons[0] != nil:
        result = typeAllowedAux(marker, t.sons[0], skResult, flags)
  of tyTypeDesc:
    # XXX: This is still a horrible idea...
    result = nil
  of tyUntyped, tyTyped, tyStatic:
    if kind notin {skParam, skResult}: result = t
  of tyVoid:
    if taField notin flags: result = t
  of tyTypeClasses:
    if tfGenericTypeParam in t.flags or taConcept in flags: #or taField notin flags:
      discard
    elif t.isResolvedUserTypeClass:
      result = typeAllowedAux(marker, t.lastSon, kind, flags)
    elif kind notin {skParam, skResult}:
      result = t
  of tyGenericBody, tyGenericParam, tyGenericInvocation,
     tyNone, tyForward, tyFromExpr:
    result = t
  of tyNil:
    if kind != skConst and kind != skParam: result = t
  of tyString, tyBool, tyChar, tyEnum, tyInt..tyUInt64, tyCString, tyPointer:
    result = nil
  of tyOrdinal:
    if kind != skParam: result = t
  of tyGenericInst, tyDistinct, tyAlias, tyInferred:
    result = typeAllowedAux(marker, lastSon(t), kind, flags)
  of tyRange:
    if skipTypes(t.sons[0], abstractInst-{tyTypeDesc}).kind notin
      {tyChar, tyEnum, tyInt..tyFloat128, tyUInt8..tyUInt32}: result = t
  of tyOpenArray, tyVarargs, tySink:
    if kind != skParam:
      result = t
    else:
      result = typeAllowedAux(marker, t.sons[0], skVar, flags)
  of tyUncheckedArray:
    if kind != skParam and taHeap notin flags:
      result = t
    else:
      result = typeAllowedAux(marker, lastSon(t), kind, flags)
  of tySequence, tyOpt:
    if t.sons[0].kind != tyEmpty:
      result = typeAllowedAux(marker, t.sons[0], skVar, flags+{taHeap})
    elif kind in {skVar, skLet}:
      result = t.sons[0]
  of tyArray:
    if t.sons[1].kind != tyEmpty:
      result = typeAllowedAux(marker, t.sons[1], skVar, flags)
    elif kind in {skVar, skLet}:
      result = t.sons[1]
  of tyRef:
    if kind == skConst: result = t
    else: result = typeAllowedAux(marker, t.lastSon, skVar, flags+{taHeap})
  of tyPtr:
    result = typeAllowedAux(marker, t.lastSon, skVar, flags+{taHeap})
  of tySet:
    for i in 0 ..< sonsLen(t):
      result = typeAllowedAux(marker, t.sons[i], kind, flags)
      if result != nil: break
  of tyObject, tyTuple:
    if kind in {skProc, skFunc, skConst} and
        t.kind == tyObject and t.sons[0] != nil:
      result = t
    else:
      let flags = flags+{taField}
      for i in 0 ..< sonsLen(t):
        result = typeAllowedAux(marker, t.sons[i], kind, flags)
        if result != nil: break
      if result.isNil and t.n != nil:
        result = typeAllowedNode(marker, t.n, kind, flags)
  of tyEmpty:
    if kind in {skVar, skLet}: result = t
  of tyProxy:
    # for now same as error node; we say it's a valid type as it should
    # prevent cascading errors:
    result = nil
  of tyOwned:
    if t.len == 1 and t.sons[0].skipTypes(abstractInst).kind in {tyRef, tyPtr, tyProc}:
      result = typeAllowedAux(marker, t.lastSon, skVar, flags+{taHeap})
    else:
      result = t

proc typeAllowed*(t: PType, kind: TSymKind; flags: TTypeAllowedFlags = {}): PType =
  # returns 'nil' on success and otherwise the part of the type that is
  # wrong!
  var marker = initIntSet()
  result = typeAllowedAux(marker, t, kind, flags)

include sizealignoffsetimpl

proc computeSize*(conf: ConfigRef; typ: PType): BiggestInt =
  computeSizeAlign(conf, typ)
  result = typ.size

proc getReturnType*(s: PSym): PType =
  # Obtains the return type of a iterator/proc/macro/template
  assert s.kind in skProcKinds
  result = s.typ.sons[0]

proc getAlign*(conf: ConfigRef; typ: PType): BiggestInt =
  computeSizeAlign(conf, typ)
  result = typ.align

proc getSize*(conf: ConfigRef; typ: PType): BiggestInt =
  computeSizeAlign(conf, typ)
  result = typ.size

proc containsGenericTypeIter(t: PType, closure: RootRef): bool =
  case t.kind
  of tyStatic:
    return t.n == nil
  of tyTypeDesc:
    if t.base.kind == tyNone: return true
    if containsGenericTypeIter(t.base, closure): return true
    return false
  of GenericTypes + tyTypeClasses + {tyFromExpr}:
    return true
  else:
    return false

proc containsGenericType*(t: PType): bool =
  result = iterOverType(t, containsGenericTypeIter, nil)

proc baseOfDistinct*(t: PType): PType =
  if t.kind == tyDistinct:
    result = t.sons[0]
  else:
    result = copyType(t, t.owner, false)
    var parent: PType = nil
    var it = result
    while it.kind in {tyPtr, tyRef, tyOwned}:
      parent = it
      it = it.lastSon
    if it.kind == tyDistinct and parent != nil:
      parent.sons[0] = it.sons[0]

proc safeInheritanceDiff*(a, b: PType): int =
  # same as inheritanceDiff but checks for tyError:
  if a.kind == tyError or b.kind == tyError:
    result = -1
  else:
    result = inheritanceDiff(a.skipTypes(skipPtrs), b.skipTypes(skipPtrs))

proc compatibleEffectsAux(se, re: PNode): bool =
  if re.isNil: return false
  for r in items(re):
    block search:
      for s in items(se):
        if safeInheritanceDiff(r.typ, s.typ) <= 0:
          break search
      return false
  result = true

type
  EffectsCompat* = enum
    efCompat
    efRaisesDiffer
    efRaisesUnknown
    efTagsDiffer
    efTagsUnknown
    efLockLevelsDiffer

proc compatibleEffects*(formal, actual: PType): EffectsCompat =
  # for proc type compatibility checking:
  assert formal.kind == tyProc and actual.kind == tyProc
  if formal.n.sons[0].kind != nkEffectList or
     actual.n.sons[0].kind != nkEffectList:
    return efTagsUnknown

  var spec = formal.n.sons[0]
  if spec.len != 0:
    var real = actual.n.sons[0]

    let se = spec.sons[exceptionEffects]
    # if 'se.kind == nkArgList' it is no formal type really, but a
    # computed effect and as such no spec:
    # 'r.msgHandler = if isNil(msgHandler): defaultMsgHandler else: msgHandler'
    if not isNil(se) and se.kind != nkArgList:
      # spec requires some exception or tag, but we don't know anything:
      if real.len == 0: return efRaisesUnknown
      let res = compatibleEffectsAux(se, real.sons[exceptionEffects])
      if not res: return efRaisesDiffer

    let st = spec.sons[tagEffects]
    if not isNil(st) and st.kind != nkArgList:
      # spec requires some exception or tag, but we don't know anything:
      if real.len == 0: return efTagsUnknown
      let res = compatibleEffectsAux(st, real.sons[tagEffects])
      if not res: return efTagsDiffer
  if formal.lockLevel.ord < 0 or
      actual.lockLevel.ord <= formal.lockLevel.ord:
    result = efCompat
  else:
    result = efLockLevelsDiffer

proc isCompileTimeOnly*(t: PType): bool {.inline.} =
  result = t.kind in {tyTypeDesc, tyStatic}

proc containsCompileTimeOnly*(t: PType): bool =
  if isCompileTimeOnly(t): return true
  for i in 0 ..< t.sonsLen:
    if t.sons[i] != nil and isCompileTimeOnly(t.sons[i]):
      return true
  return false

type
  OrdinalType* = enum
    NoneLike, IntLike, FloatLike

proc classify*(t: PType): OrdinalType =
  ## for convenient type checking:
  if t == nil:
    result = NoneLike
  else:
    case skipTypes(t, abstractVarRange).kind
    of tyFloat..tyFloat128: result = FloatLike
    of tyInt..tyInt64, tyUInt..tyUInt64, tyBool, tyChar, tyEnum:
      result = IntLike
    else: result = NoneLike

proc skipConv*(n: PNode): PNode =
  result = n
  case n.kind
  of nkObjUpConv, nkObjDownConv, nkChckRange, nkChckRangeF, nkChckRange64:
    # only skip the conversion if it doesn't lose too important information
    # (see bug #1334)
    if n.sons[0].typ.classify == n.typ.classify:
      result = n.sons[0]
  of nkHiddenStdConv, nkHiddenSubConv, nkConv:
    if n.sons[1].typ.classify == n.typ.classify:
      result = n.sons[1]
  else: discard

proc skipHidden*(n: PNode): PNode =
  result = n
  while true:
    case result.kind
    of nkHiddenStdConv, nkHiddenSubConv:
      if result.sons[1].typ.classify == result.typ.classify:
        result = result.sons[1]
      else: break
    of nkHiddenDeref, nkHiddenAddr:
      result = result.sons[0]
    else: break

proc skipConvTakeType*(n: PNode): PNode =
  result = n.skipConv
  result.typ = n.typ

proc isEmptyContainer*(t: PType): bool =
  case t.kind
  of tyUntyped, tyNil: result = true
  of tyArray: result = t.sons[1].kind == tyEmpty
  of tySet, tySequence, tyOpenArray, tyVarargs:
    result = t.sons[0].kind == tyEmpty
  of tyGenericInst, tyAlias, tySink: result = isEmptyContainer(t.lastSon)
  else: result = false

proc takeType*(formal, arg: PType): PType =
  # param: openArray[string] = []
  # [] is an array constructor of length 0 of type string!
  if arg.kind == tyNil:
    # and not (formal.kind == tyProc and formal.callConv == ccClosure):
    result = formal
  elif formal.kind in {tyOpenArray, tyVarargs, tySequence} and
      arg.isEmptyContainer:
    let a = copyType(arg.skipTypes({tyGenericInst, tyAlias}), arg.owner, keepId=false)
    a.sons[ord(arg.kind == tyArray)] = formal.sons[0]
    result = a
  elif formal.kind in {tyTuple, tySet} and arg.kind == formal.kind:
    result = formal
  else:
    result = arg

proc skipHiddenSubConv*(n: PNode): PNode =
  if n.kind == nkHiddenSubConv:
    # param: openArray[string] = []
    # [] is an array constructor of length 0 of type string!
    let formal = n.typ
    result = n.sons[1]
    let arg = result.typ
    let dest = takeType(formal, arg)
    if dest == arg and formal.kind != tyUntyped:
      #echo n.info, " came here for ", formal.typeToString
      result = n
    else:
      result = copyTree(result)
      result.typ = dest
  else:
    result = n

proc typeMismatch*(conf: ConfigRef; info: TLineInfo, formal, actual: PType) =
  if formal.kind != tyError and actual.kind != tyError:
    let named = typeToString(formal)
    let desc = typeToString(formal, preferDesc)
    let x = if named == desc: named else: named & " = " & desc
    var msg = "type mismatch: got <" &
              typeToString(actual) & "> " &
              "but expected '" & x & "'"

    if formal.kind == tyProc and actual.kind == tyProc:
      case compatibleEffects(formal, actual)
      of efCompat: discard
      of efRaisesDiffer:
        msg.add "\n.raise effects differ"
      of efRaisesUnknown:
        msg.add "\n.raise effect is 'can raise any'"
      of efTagsDiffer:
        msg.add "\n.tag effects differ"
      of efTagsUnknown:
        msg.add "\n.tag effect is 'any tag allowed'"
      of efLockLevelsDiffer:
        msg.add "\nlock levels differ"
    localError(conf, info, msg)

proc isTupleRecursive(t: PType, cycleDetector: var IntSet): bool =
  if t == nil:
    return false
  if cycleDetector.containsOrIncl(t.id):
    return true
  case t.kind:
    of tyTuple:
      var cycleDetectorCopy: IntSet
      for i in  0..<t.len:
        assign(cycleDetectorCopy, cycleDetector)
        if isTupleRecursive(t[i], cycleDetectorCopy):
          return true
    of tyAlias, tyRef, tyPtr, tyGenericInst, tyVar, tyLent, tySink, tyArray, tyUncheckedArray, tySequence:
      return isTupleRecursive(t.lastSon, cycleDetector)
    else:
      return false

proc isTupleRecursive*(t: PType): bool =
  var cycleDetector = initIntSet()
  isTupleRecursive(t, cycleDetector)

proc isException*(t: PType): bool =
  # check if `y` is object type and it inherits from Exception
  assert(t != nil)

  var t = t.skipTypes(abstractInst)
  while t.kind == tyObject:
    if t.sym != nil and t.sym.magic == mException: return true
    if t.sons[0] == nil: break
    t = skipTypes(t.sons[0], abstractPtrs)
  return false
