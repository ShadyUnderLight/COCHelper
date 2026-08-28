#!/usr/bin/env node
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ts = createRequire(import.meta.url)('typescript');

const defaultRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FORBIDDEN_PACKAGE = '@coc-helper/testkit';
const PACKAGED_MARKERS = [FORBIDDEN_PACKAGE, 'packages/testkit', 'COCHELPER_SWIFT_ORACLE', 'golden-oracle'];
const WORKSPACE_PACKAGES = {
  '@coc-helper/testkit': 'packages/testkit',
  '@coc-helper/wire': 'packages/wire',
  '@coc-helper/domain': 'packages/domain',
  '@coc-helper/contracts': 'packages/contracts',
  '@coc-helper/desktop': 'apps/desktop',
};

const PRODUCTION_TREES = [
  'apps/desktop/src',
  'packages/wire/src',
  'packages/domain/src',
  'packages/contracts/src',
];

const PRODUCTION_ENTRIES = [
  'apps/desktop/src/main/index.ts',
  'apps/desktop/src/preload/index.ts',
  'apps/desktop/src/renderer/index.ts',
  'packages/wire/src/index.ts',
  'packages/domain/src/index.ts',
  'packages/contracts/src/index.ts',
];

const MUTATING_ARRAY_METHODS = new Set([
  'push',
  'pop',
  'shift',
  'unshift',
  'splice',
  'sort',
  'reverse',
  'fill',
  'copyWithin',
]);

const ARRAY_QUERY_METHODS = new Set([
  'at',
  'slice',
  'concat',
  'map',
  'filter',
  'flat',
  'flatMap',
  'toReversed',
  'toSpliced',
  'toSorted',
  'with',
]);
const LOADERISH_PROPERTIES = new Set(['get', 'require', 'createRequire', 'loader', 'req']);

function walk(dir, { includeNodeModules = false } = {}, seenDirectories = new Set()) {
  if (!existsSync(dir)) {
    return [];
  }
  const realDirectory = realpathSync(dir);
  if (seenDirectories.has(realDirectory)) {
    return [];
  }
  seenDirectories.add(realDirectory);
  const out = [];
  for (const entry of readdirSync(dir)) {
    if ((!includeNodeModules && entry === 'node_modules') || (entry.startsWith('.') && entry !== '.webpack')) {
      continue;
    }
    const full = path.join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      out.push(...walk(full, { includeNodeModules }, seenDirectories));
    } else {
      out.push(full);
    }
  }
  return out;
}

export function extractImportSpecifiers(text, fileName = 'module.ts') {
  return collectModuleLoads(text, fileName)
    .filter((item) => item.kind === 'specifier')
    .map((item) => item.value);
}

export function extractUnsafeDynamicLoads(text, fileName = 'module.ts') {
  return collectModuleLoads(text, fileName)
    .filter((item) => item.kind === 'unsafe')
    .map((item) => item.reason);
}

function collectModuleLoads(text, fileName) {
  const sourceFile = ts.createSourceFile(
    fileName,
    text,
    ts.ScriptTarget.Latest,
    true,
    scriptKindFor(fileName),
  );
  const factories = new Set();
  const requirers = new Set(['require']);
  const arrayShapes = new Map();
  const valueKinds = new Map();
  const mutatorAliases = new Set();
  const stringValues = new Map();
  const functionReturns = new Map();
  const functionReturnShapes = new Map();
  const functionReturnExprs = new Map();
  const classInstances = new Map();
  const classParents = new Map();
  const valueExprs = new Map();
  const arrayMethodAliases = new Map();
  const objectAssignAliases = new Set();
  const arrayFromAliases = new Set();
  const arrayOfAliases = new Set();
  const arrayCtorAliases = new Set();
  const reflectApplyAliases = new Set();
  const callApplyAliases = new Set();
  const objectCreateAliases = new Set();
  const objectSetPrototypeOfAliases = new Set();
  const objectDefinePropertyAliases = new Set();
  const objectDefinePropertiesAliases = new Set();
  const reflectConstructAliases = new Set();
  const functionParams = new Map();
  const prototypeExprs = new Map();
  const scopedBindingKinds = new WeakMap();
  const scopedArrayShapes = new WeakMap();
  const paramsUsedAsCallees = new WeakSet();
  const paramsUsedAsCalleeKeys = new Set();
  const paramBindingKinds = new Map();

  const opaqueArrayShape = () => ({ opaque: true, kinds: [], values: [] });

  const shapeOf = (opaque, kinds, values = []) => {
    const nextValues = values.length === kinds.length ? values : kinds.map((_, i) => values[i]);
    return { opaque, kinds, values: nextValues };
  };

  const UNRESOLVABLE_TARGET = Object.freeze({});

  const dangerousShapeKind = (shape) => {
    if (!shape) return null;
    return shape.kinds.find((k) => k === 'factory' || k === 'requirer') ?? (shape.opaque ? 'requirer' : null);
  };

  const referenceKey = (expr) => {
    expr = unwrapExpr(expr);
    if (!expr) {
      return null;
    }
    if (ts.isIdentifier(expr)) {
      return expr.text;
    }
    if (ts.isPropertyAccessExpression(expr) && ts.isIdentifier(expr.name)) {
      const base = referenceKey(expr.expression);
      return base ? `${base}.${expr.name.text}` : null;
    }
    if (ts.isElementAccessExpression(expr)) {
      const argument = unwrapExpr(expr.argumentExpression);
      const property = argument ? staticStringValue(argument) : null;
      if (property === null) {
        return null;
      }
      const base = referenceKey(expr.expression);
      return base ? `${base}.${property}` : null;
    }
    return null;
  };

  const staticMember = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (unwrapped && ts.isPropertyAccessExpression(unwrapped) && ts.isIdentifier(unwrapped.name)) {
      return { object: unwrapped.expression, name: unwrapped.name.text };
    }
    if (unwrapped && ts.isElementAccessExpression(unwrapped)) {
      const argument = unwrapExpr(unwrapped.argumentExpression);
      const property = argument ? staticStringValue(argument) : null;
      if (property !== null) {
        return { object: unwrapped.expression, name: property };
      }
    }
    return null;
  };

  const isObjectIdentifier = (expr, name) => {
    const unwrapped = unwrapExpr(expr);
    return Boolean(unwrapped && ts.isIdentifier(unwrapped) && unwrapped.text === name);
  };

  const isObjectAssignCallee = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    if (ts.isIdentifier(unwrapped) && objectAssignAliases.has(unwrapped.text)) {
      return true;
    }
    const key = referenceKey(unwrapped);
    if (key !== null && objectAssignAliases.has(key)) {
      return true;
    }
    const access = staticMember(unwrapped);
    if (!access) {
      return false;
    }
    if (access.name === 'assign' && isObjectIdentifier(access.object, 'Object')) {
      return true;
    }
    if (access.name === 'assign') {
      const resolved = resolveObjectProperty(access.object, 'assign');
      if (resolved?.value && resolved.value !== unwrapped) {
        return isObjectAssignCallee(resolved.value);
      }
    }
    return false;
  };

  const isObjectAssignCall = (expr) => objectAssignArguments(expr) !== undefined;

  const objectAssignArguments = (expr) => {
    const inv = invocationOf(expr);
    if (!inv || !isObjectAssignCallee(inv.callee)) {
      return undefined;
    }
    return inv.droppedSpread ? null : inv.args;
  };

  const isArrayFromCallee = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    if (ts.isIdentifier(unwrapped) && arrayFromAliases.has(unwrapped.text)) {
      return true;
    }
    const key = referenceKey(unwrapped);
    if (key !== null && arrayFromAliases.has(key)) {
      return true;
    }
    const access = staticMember(unwrapped);
    return Boolean(access?.name === 'from' && isObjectIdentifier(access.object, 'Array'));
  };

  const isArrayOfCallee = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    if (ts.isIdentifier(unwrapped) && arrayOfAliases.has(unwrapped.text)) {
      return true;
    }
    const key = referenceKey(unwrapped);
    if (key !== null && arrayOfAliases.has(key)) {
      return true;
    }
    const access = staticMember(unwrapped);
    return Boolean(access?.name === 'of' && isObjectIdentifier(access.object, 'Array'));
  };

  const isArrayConstructorCallee = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    if (ts.isIdentifier(unwrapped) && (unwrapped.text === 'Array' || arrayCtorAliases.has(unwrapped.text))) {
      return true;
    }
    const key = referenceKey(unwrapped);
    return key !== null && arrayCtorAliases.has(key);
  };

  const isObjectDefinePropertyCallee = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    if (ts.isIdentifier(unwrapped) && objectDefinePropertyAliases.has(unwrapped.text)) {
      return true;
    }
    const key = referenceKey(unwrapped);
    if (key !== null && objectDefinePropertyAliases.has(key)) {
      return true;
    }
    const access = staticMember(unwrapped);
    return Boolean(
      access &&
        access.name === 'defineProperty' &&
        (isObjectIdentifier(access.object, 'Object') || isObjectIdentifier(access.object, 'Reflect')),
    );
  };

  const isObjectDefinePropertiesCallee = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    if (ts.isIdentifier(unwrapped) && objectDefinePropertiesAliases.has(unwrapped.text)) {
      return true;
    }
    const key = referenceKey(unwrapped);
    if (key !== null && objectDefinePropertiesAliases.has(key)) {
      return true;
    }
    const access = staticMember(unwrapped);
    return Boolean(access?.name === 'defineProperties' && isObjectIdentifier(access.object, 'Object'));
  };

  const isObjectCreateCallee = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    if (ts.isIdentifier(unwrapped) && objectCreateAliases.has(unwrapped.text)) {
      return true;
    }
    const key = referenceKey(unwrapped);
    if (key !== null && objectCreateAliases.has(key)) {
      return true;
    }
    const access = staticMember(unwrapped);
    return Boolean(access?.name === 'create' && isObjectIdentifier(access.object, 'Object'));
  };

  const isObjectSetPrototypeOfCallee = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    if (ts.isIdentifier(unwrapped) && objectSetPrototypeOfAliases.has(unwrapped.text)) {
      return true;
    }
    const key = referenceKey(unwrapped);
    if (key !== null && objectSetPrototypeOfAliases.has(key)) {
      return true;
    }
    const access = staticMember(unwrapped);
    return Boolean(access?.name === 'setPrototypeOf' && isObjectIdentifier(access.object, 'Object'));
  };

  const isReflectConstructCallee = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    if (ts.isIdentifier(unwrapped) && reflectConstructAliases.has(unwrapped.text)) {
      return true;
    }
    const key = referenceKey(unwrapped);
    if (key !== null && reflectConstructAliases.has(key)) {
      return true;
    }
    const access = staticMember(unwrapped);
    return Boolean(access?.name === 'construct' && isObjectIdentifier(access.object, 'Reflect'));
  };

  const registerBuiltinCalleeAliases = (toName, fromExpr) => {
    const unwrapped = unwrapExpr(fromExpr);
    if (!unwrapped) {
      return;
    }
    if (ts.isCallExpression(unwrapped)) {
      const bindAccess = staticMember(unwrapped.expression);
      if (bindAccess?.name === 'bind') {
        registerBuiltinCalleeAliases(toName, bindAccess.object);
        return;
      }
    }
    if (isObjectAssignCallee(unwrapped)) {
      objectAssignAliases.add(toName);
    }
    if (isArrayFromCallee(unwrapped)) {
      arrayFromAliases.add(toName);
    }
    if (isArrayOfCallee(unwrapped)) {
      arrayOfAliases.add(toName);
    }
    if (isArrayConstructorCallee(unwrapped)) {
      arrayCtorAliases.add(toName);
    }
    if (isObjectCreateCallee(unwrapped)) {
      objectCreateAliases.add(toName);
    }
    if (isObjectSetPrototypeOfCallee(unwrapped)) {
      objectSetPrototypeOfAliases.add(toName);
    }
    if (isObjectDefinePropertyCallee(unwrapped)) {
      objectDefinePropertyAliases.add(toName);
    }
    if (isObjectDefinePropertiesCallee(unwrapped)) {
      objectDefinePropertiesAliases.add(toName);
    }
    if (isReflectConstructCallee(unwrapped)) {
      reflectConstructAliases.add(toName);
    }
    if (isReflectApplyCallee(unwrapped)) {
      reflectApplyAliases.add(toName);
    }
  };

  const isNodeInside = (node, ancestor) => {
    if (!ancestor) {
      return false;
    }
    let current = node;
    while (current) {
      if (current === ancestor) {
        return true;
      }
      current = current.parent;
    }
    return false;
  };

  const patternBindsName = (pattern, name) => {
    if (!pattern) {
      return false;
    }
    if (ts.isIdentifier(pattern)) {
      return pattern.text === name;
    }
    if (ts.isObjectBindingPattern(pattern) || ts.isArrayBindingPattern(pattern)) {
      return pattern.elements.some(
        (element) => ts.isBindingElement(element) && patternBindsName(element.name, name),
      );
    }
    return false;
  };

  const bindingNameNode = (pattern, name) => {
    if (!pattern) {
      return null;
    }
    if (ts.isIdentifier(pattern)) {
      return pattern.text === name ? pattern : null;
    }
    if (ts.isObjectBindingPattern(pattern) || ts.isArrayBindingPattern(pattern)) {
      for (const element of pattern.elements) {
        if (!ts.isBindingElement(element)) {
          continue;
        }
        const found = bindingNameNode(element.name, name);
        if (found) {
          return found;
        }
      }
    }
    return null;
  };

  const enclosingBindingName = (ident) => {
    if (!ident || !ts.isIdentifier(ident)) {
      return null;
    }
    let current = ident.parent;
    while (current) {
      if (ts.isSourceFile(current) || ts.isBlock(current) || ts.isModuleBlock(current) || ts.isCaseClause(current) || ts.isDefaultClause(current)) {
        for (const stmt of current.statements) {
          if (ts.isVariableStatement(stmt)) {
            const isBlockScoped = Boolean(stmt.declarationList.flags & (ts.NodeFlags.Let | ts.NodeFlags.Const));
            for (const decl of stmt.declarationList.declarations) {
              if (!patternBindsName(decl.name, ident.text)) {
                continue;
              }
              if (ident === decl.name || isNodeInside(ident, decl.name) || isNodeInside(ident, decl.initializer)) {
                continue;
              }
              if (isBlockScoped && ident.pos < decl.pos) {
                continue;
              }
              return bindingNameNode(decl.name, ident.text);
            }
          }
          if (
            ts.isFunctionDeclaration(stmt) &&
            stmt.name &&
            stmt.name.text === ident.text &&
            stmt.name !== ident &&
            ident.pos >= stmt.pos
          ) {
            return stmt.name;
          }
        }
      }
      if (isFunctionLikeNode(current) && current.parameters) {
        for (const param of current.parameters) {
          if (patternBindsName(param.name, ident.text) && !isNodeInside(ident, param.initializer)) {
            return bindingNameNode(param.name, ident.text);
          }
        }
      }
      if (
        ts.isCatchClause(current) &&
        current.variableDeclaration &&
        patternBindsName(current.variableDeclaration.name, ident.text) &&
        !isNodeInside(ident, current.variableDeclaration.name)
      ) {
        return bindingNameNode(current.variableDeclaration.name, ident.text);
      }
      if (ts.isForOfStatement(current) || ts.isForInStatement(current) || ts.isForStatement(current)) {
        if (ts.isForOfStatement(current) || ts.isForInStatement(current)) {
          if (isNodeInside(ident, current.expression)) {
            current = current.parent;
            continue;
          }
        }
        const init = current.initializer;
        if (init && ts.isVariableDeclarationList(init)) {
          const isBlockScoped = Boolean(init.flags & (ts.NodeFlags.Let | ts.NodeFlags.Const));
          for (const decl of init.declarations) {
            if (!patternBindsName(decl.name, ident.text)) {
              continue;
            }
            if (ident === decl.name || isNodeInside(ident, decl.name) || isNodeInside(ident, decl.initializer)) {
              continue;
            }
            if (isBlockScoped && ident.pos < decl.pos) {
              continue;
            }
            return bindingNameNode(decl.name, ident.text);
          }
        }
      }
      current = current.parent;
    }
    return null;
  };

  const scopedIdentifierKind = (ident) => {
    if (!ident || !ts.isIdentifier(ident)) {
      return undefined;
    }
    const param = parameterFromName(ident);
    if (param?.parent && isFunctionLikeNode(param.parent)) {
      const funcNode = param.parent;
      const funcKey = funcNode.name ? referenceKey(funcNode.name) : callableReferenceKey(funcNode);
      if (funcKey !== null) {
        const boundKind = paramBindingKinds.get(`${funcKey}#${ident.text}`);
        if (boundKind === 'factory' || boundKind === 'requirer') {
          return boundKind;
        }
      }
    }
    const decl = enclosingBindingName(ident);
    if (!decl) {
      return undefined;
    }
    if (!scopedBindingKinds.has(decl)) {
      return undefined;
    }
    const scoped = scopedBindingKinds.get(decl);
    if (scoped === 'factory' || scoped === 'requirer') {
      return scoped;
    }
    return undefined;
  };

  const parameterFromName = (name) => {
    let current = name;
    while (current) {
      if (ts.isParameter(current)) {
        return current;
      }
      current = current.parent;
    }
    return null;
  };

  const isReflectApplyCallee = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    if (ts.isIdentifier(unwrapped) && reflectApplyAliases.has(unwrapped.text)) {
      return true;
    }
    const access = staticMember(unwrapped);
    return Boolean(access?.name === 'apply' && isObjectIdentifier(access.object, 'Reflect'));
  };

  const isCallOrApplyValue = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    if (ts.isIdentifier(unwrapped) && callApplyAliases.has(unwrapped.text)) {
      return true;
    }
    const member = staticMember(unwrapped);
    return member?.name === 'call' || member?.name === 'apply';
  };

  const isFunctionPrototypeCallApply = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    const access = staticMember(unwrapped);
    if (!access || (access.name !== 'call' && access.name !== 'apply')) {
      return false;
    }
    const proto = staticMember(access.object);
    return Boolean(proto?.name === 'prototype' && isObjectIdentifier(proto.object, 'Function'));
  };

  const resolveCallApplyKind = (expr) => {
    const unwrapped = resolveAliasedValue(expr);
    if (!unwrapped) {
      return null;
    }
    const access = staticMember(unwrapped);
    if (access?.name === 'apply') {
      return 'apply';
    }
    if (access?.name === 'call') {
      return 'call';
    }
    return 'call';
  };

  const resolveBorrowedCallTarget = (expr, seen = new Set()) => {
    const unwrapped = resolveAliasedValue(expr);
    if (!unwrapped || seen.has(unwrapped)) {
      return null;
    }
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    const access = staticMember(unwrapped);
    if (!access || (access.name !== 'call' && access.name !== 'apply')) {
      return null;
    }
    if (isFunctionPrototypeCallApply(unwrapped)) {
      return null;
    }
    return access.object;
  };

  const callApplyBindingFrom = (callee, rawArgs) => {
    const calleeUnwrapped = unwrapExpr(callee);
    const flat = flattenCallArguments(rawArgs);
    if (isReflectApplyCallee(calleeUnwrapped)) {
      const fnExpr = flat.items[0];
      const argsArrayExpr = flat.items[2];
      const expanded = argsArrayExpr
        ? expandSpread(argsArrayExpr)
        : { items: [], complete: !flat.unresolvable, dropped: false };
      if (expanded === null) {
        return {
          targetExpr: fnExpr ?? null,
          fnArgs: [],
          unresolvable: true,
        };
      }
      return {
        targetExpr: fnExpr ?? null,
        fnArgs: expanded.items,
        unresolvable: flat.unresolvable || !expanded.complete,
      };
    }
    const access = staticMember(calleeUnwrapped);
    if (access && (access.name === 'call' || access.name === 'apply')) {
      if (isReflectApplyCallee(access.object) || isCallOrApplyValue(access.object)) {
        const targetExpr = flat.items[0] ?? null;
        if (access.name === 'call') {
          return {
            targetExpr,
            fnArgs: flat.items.slice(2),
            unresolvable: flat.unresolvable,
          };
        }
        const argsArrayExpr = flat.items[2];
        const expanded = argsArrayExpr
          ? expandSpread(argsArrayExpr)
          : { items: [], complete: !flat.unresolvable, dropped: false };
        if (expanded === null) {
          return { targetExpr, fnArgs: [], unresolvable: true };
        }
        return {
          targetExpr,
          fnArgs: expanded.items,
          unresolvable: flat.unresolvable || !expanded.complete,
        };
      }
      const borrowed = borrowedCallArgsFrom(rawArgs, access.name);
      return {
        targetExpr: access.object,
        fnArgs: borrowed?.args ?? [],
        unresolvable: !borrowed || borrowed.unresolvable,
      };
    }
    if (isCallOrApplyValue(calleeUnwrapped)) {
      const borrowedTarget = resolveBorrowedCallTarget(calleeUnwrapped);
      if (borrowedTarget) {
        const kind = resolveCallApplyKind(calleeUnwrapped) ?? 'call';
        const borrowed = borrowedCallArgsFrom(rawArgs, kind);
        return {
          targetExpr: borrowedTarget,
          fnArgs: borrowed?.args ?? [],
          unresolvable: !borrowed || borrowed.unresolvable,
        };
      }
      const targetExpr = flat.items[0] ?? null;
      if (resolveCallApplyKind(calleeUnwrapped) === 'apply') {
        const argsArrayExpr = flat.items[2];
        const expanded = argsArrayExpr
          ? expandSpread(argsArrayExpr)
          : { items: [], complete: !flat.unresolvable, dropped: false };
        if (expanded === null) {
          return { targetExpr, fnArgs: [], unresolvable: true };
        }
        return {
          targetExpr,
          fnArgs: expanded.items,
          unresolvable: flat.unresolvable || !expanded.complete,
        };
      }
      return {
        targetExpr,
        fnArgs: flat.items.slice(2),
        unresolvable: flat.unresolvable,
      };
    }
    return null;
  };

  const resolveArrayMethodAlias = (expr, seen = new Set()) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return null;
    }
    if (seen.has(unwrapped)) {
      return null;
    }
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    if (ts.isIdentifier(unwrapped)) {
      if (arrayMethodAliases.has(unwrapped.text)) {
        return arrayMethodAliases.get(unwrapped.text);
      }
      const stored = valueExprs.get(unwrapped.text);
      return stored ? resolveArrayMethodAlias(stored, nextSeen) : null;
    }
    const bound = unwrapBindCall(unwrapped);
    if (bound.target !== unwrapped) {
      const aliased = resolveArrayMethodAlias(bound.target, nextSeen);
      if (aliased) {
        return { method: aliased.method, object: bound.thisArg ?? aliased.object };
      }
    }
    if (ts.isCallExpression(unwrapped)) {
      for (const returned of returnExprsForCallable(unwrapped.expression)) {
        const aliased = resolveArrayMethodAlias(returned, nextSeen);
        if (aliased) {
          return aliased;
        }
      }
    }
    const key = referenceKey(unwrapped);
    if (key !== null) {
      if (arrayMethodAliases.has(key)) {
        return arrayMethodAliases.get(key);
      }
      const stored = valueExprs.get(key);
      if (stored && stored !== unwrapped) {
        const aliased = resolveArrayMethodAlias(stored, nextSeen);
        if (aliased) {
          return aliased;
        }
      }
    }
    const access = staticMember(unwrapped);
    if (access && ARRAY_QUERY_METHODS.has(access.name)) {
      return { method: access.name, object: access.object };
    }
    return null;
  };

  const expandSpread = (expr, seen = new Set()) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return null;
    }
    if (seen.has(unwrapped)) {
      return null;
    }
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    if (ts.isArrayLiteralExpression(unwrapped)) {
      const items = [];
      let complete = true;
      let dropped = false;
      for (const el of unwrapped.elements) {
        if (ts.isOmittedExpression(el)) {
          items.push(undefined);
          continue;
        }
        if (ts.isSpreadElement(el)) {
          const inner = expandSpread(el.expression, nextSeen);
          if (inner === null) {
            complete = false;
            dropped = true;
            continue;
          }
          items.push(...inner.items);
          complete = complete && inner.complete;
          dropped = dropped || inner.dropped;
          continue;
        }
        items.push(el);
      }
      return { items, complete, dropped };
    }
    const shape = shapeForValue(unwrapped);
    if (shape?.values) {
      return { items: shape.values.filter(Boolean), complete: !shape.opaque, dropped: false };
    }
    return null;
  };

  const flattenCallArguments = (args) => {
    const items = [];
    let unresolvable = false;
    let droppedSpread = false;
    for (const arg of args) {
      if (ts.isSpreadElement(arg)) {
        const expanded = expandSpread(arg.expression);
        if (expanded === null) {
          unresolvable = true;
          droppedSpread = true;
          continue;
        }
        items.push(...expanded.items);
        if (!expanded.complete) {
          unresolvable = true;
        }
        droppedSpread = droppedSpread || expanded.dropped;
        continue;
      }
      items.push(arg);
    }
    return { items, unresolvable, droppedSpread };
  };

  const unwrapBindCall = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped || !ts.isCallExpression(unwrapped)) {
      return { target: unwrapped, thisArg: null, boundArgs: [] };
    }
    const access = staticMember(unwrapped.expression);
    if (access?.name !== 'bind') {
      return { target: unwrapped, thisArg: null, boundArgs: [] };
    }
    const inner = unwrapBindCall(access.object);
    return {
      target: inner.target,
      thisArg: unwrapped.arguments[0] ?? inner.thisArg,
      boundArgs: [...inner.boundArgs, ...unwrapped.arguments.slice(1)],
    };
  };

  const borrowedCallArgsFrom = (argNodes, kind) => {
    const flat = flattenCallArguments(argNodes);
    if (kind === 'call') {
      if (flat.unresolvable && flat.items.length === 0) {
        return null;
      }
      return {
        thisArg: flat.items[0] ?? null,
        args: flat.items.slice(1),
        unresolvable: flat.unresolvable,
        droppedSpread: flat.droppedSpread,
      };
    }
    const restExpr = flat.items[1];
    const rest = restExpr ? expandSpread(restExpr) : { items: [], complete: true, dropped: false };
    if (rest === null) {
      return {
        thisArg: flat.items[0] ?? null,
        args: [],
        unresolvable: true,
        droppedSpread: true,
      };
    }
    return {
      thisArg: flat.items[0] ?? null,
      args: rest.items,
      unresolvable: flat.unresolvable || !rest.complete,
      droppedSpread: flat.droppedSpread || rest.dropped,
    };
  };

  const invocationOf = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped || !ts.isCallExpression(unwrapped)) {
      return null;
    }
    const bound = unwrapBindCall(unwrapped.expression);
    const callee = unwrapExpr(bound.target);
    const rawArgs = [...bound.boundArgs, ...unwrapped.arguments];
    const access = staticMember(callee);
    if (access && (access.name === 'call' || access.name === 'apply')) {
      const borrowed = borrowedCallArgsFrom(rawArgs, access.name);
      return {
        callee: unwrapExpr(access.object),
        args: borrowed?.args ?? [],
        unresolvable: !borrowed || borrowed.unresolvable,
        droppedSpread: !borrowed || borrowed.droppedSpread,
        thisArg: borrowed?.thisArg ?? bound.thisArg,
      };
    }
    const flat = flattenCallArguments(rawArgs);
    return {
      callee,
      args: flat.items,
      unresolvable: flat.unresolvable,
      droppedSpread: flat.droppedSpread,
      thisArg: bound.thisArg,
    };
  };

  const arrayCallParts = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped || !ts.isCallExpression(unwrapped)) {
      return null;
    }
    const bound = unwrapBindCall(unwrapped.expression);
    const callee = unwrapExpr(bound.target);
    const aliased = resolveArrayMethodAlias(callee);
    const rawArgs = [...bound.boundArgs, ...unwrapped.arguments];
    const flatArgs = flattenCallArguments(rawArgs);
    const argsUnresolvable = flatArgs.unresolvable;
    const args = flatArgs.items;
    if (aliased) {
      return { method: aliased.method, object: bound.thisArg ?? aliased.object, args, argsUnresolvable };
    }
    const access = staticMember(callee);
    if (access && (access.name === 'call' || access.name === 'apply')) {
      const methodAlias = resolveArrayMethodAlias(access.object);
      if (methodAlias) {
        const borrowed = borrowedCallArgsFrom(rawArgs, access.name);
        if (borrowed === null) {
          return {
            method: methodAlias.method,
            object: bound.thisArg ?? methodAlias.object,
            args: [],
            argsUnresolvable: true,
          };
        }
        return {
          method: methodAlias.method,
          object: borrowed.thisArg ?? bound.thisArg ?? methodAlias.object,
          args: borrowed.args,
          argsUnresolvable: Boolean(borrowed.unresolvable),
        };
      }
    }
    if (access && ARRAY_QUERY_METHODS.has(access.name)) {
      return { method: access.name, object: bound.thisArg ?? access.object, args, argsUnresolvable };
    }
    return null;
  };

  const applyTarget = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped || !ts.isCallExpression(unwrapped)) {
      return null;
    }
    const bound = unwrapBindCall(unwrapped.expression);
    const callee = unwrapExpr(bound.target);
    const flatArgs = flattenCallArguments(unwrapped.arguments);
    if (flatArgs.unresolvable && (isReflectApplyCallee(callee) || isCallOrApplyValue(callee)) && !flatArgs.items[0]) {
      return UNRESOLVABLE_TARGET;
    }
    const firstArg = flatArgs.items[0] ?? (flatArgs.unresolvable ? null : unwrapped.arguments[0]);
    if (isReflectApplyCallee(callee)) {
      return firstArg ?? null;
    }
    const access = staticMember(callee);
    if (access?.name !== 'call' && access?.name !== 'apply') {
      return null;
    }
    if (isReflectApplyCallee(access.object) || isCallOrApplyValue(access.object)) {
      return firstArg ?? null;
    }
    return access.object;
  };

  const bindIndirectAliases = (toName, fromExpr) => {
    const unwrapped = unwrapExpr(fromExpr);
    if (!unwrapped) {
      return;
    }
    registerBuiltinCalleeAliases(toName, fromExpr);
    if (ts.isIdentifier(unwrapped)) {
      if (arrayMethodAliases.has(unwrapped.text)) {
        arrayMethodAliases.set(toName, arrayMethodAliases.get(unwrapped.text));
      }
      if (objectAssignAliases.has(unwrapped.text)) {
        objectAssignAliases.add(toName);
      }
      if (arrayFromAliases.has(unwrapped.text)) {
        arrayFromAliases.add(toName);
      }
      if (arrayOfAliases.has(unwrapped.text)) {
        arrayOfAliases.add(toName);
      }
      if (unwrapped.text === 'Array' || arrayCtorAliases.has(unwrapped.text)) {
        arrayCtorAliases.add(toName);
      }
      if (reflectApplyAliases.has(unwrapped.text)) {
        reflectApplyAliases.add(toName);
      }
      if (callApplyAliases.has(unwrapped.text)) {
        callApplyAliases.add(toName);
      }
      if (objectCreateAliases.has(unwrapped.text)) {
        objectCreateAliases.add(toName);
      }
      if (objectSetPrototypeOfAliases.has(unwrapped.text)) {
        objectSetPrototypeOfAliases.add(toName);
      }
      if (objectDefinePropertyAliases.has(unwrapped.text)) {
        objectDefinePropertyAliases.add(toName);
      }
      if (objectDefinePropertiesAliases.has(unwrapped.text)) {
        objectDefinePropertiesAliases.add(toName);
      }
      if (reflectConstructAliases.has(unwrapped.text)) {
        reflectConstructAliases.add(toName);
      }
    }
    const methodAlias = resolveArrayMethodAlias(unwrapped);
    if (methodAlias) {
      arrayMethodAliases.set(toName, methodAlias);
    }
    if (ts.isCallExpression(unwrapped)) {
      const bindAccess = staticMember(unwrapped.expression);
      if (bindAccess?.name === 'bind') {
        const aliased = resolveArrayMethodAlias(bindAccess.object);
        if (aliased) {
          arrayMethodAliases.set(toName, {
            method: aliased.method,
            object: unwrapped.arguments[0] ?? aliased.object,
          });
        }
        if (isReflectApplyCallee(bindAccess.object)) {
          reflectApplyAliases.add(toName);
        }
      }
    }
    const access = staticMember(unwrapped);
    if (!access) {
      return;
    }
    const object = unwrapExpr(access.object);
    if (access.name === 'assign' && isObjectIdentifier(object, 'Object')) {
      objectAssignAliases.add(toName);
    }
    if (access.name === 'from' && isObjectIdentifier(object, 'Array')) {
      arrayFromAliases.add(toName);
    }
    if (access.name === 'of' && isObjectIdentifier(object, 'Array')) {
      arrayOfAliases.add(toName);
    }
    if (access.name === 'apply' && isObjectIdentifier(object, 'Reflect')) {
      reflectApplyAliases.add(toName);
    }
    if (access.name === 'call' || access.name === 'apply') {
      callApplyAliases.add(toName);
    }
  };

  const staticStringValue = (expr, seen = new Set()) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return null;
    }
    if (ts.isStringLiteralLike(unwrapped)) {
      return unwrapped.text;
    }
    if (ts.isIdentifier(unwrapped)) {
      if (seen.has(unwrapped.text)) {
        return null;
      }
      const nextSeen = new Set(seen);
      nextSeen.add(unwrapped.text);
      return stringValues.get(unwrapped.text) ?? null;
    }
    if (ts.isBinaryExpression(unwrapped) && unwrapped.operatorToken.kind === ts.SyntaxKind.PlusToken) {
      const left = staticStringValue(unwrapped.left, seen);
      const right = staticStringValue(unwrapped.right, seen);
      return left !== null && right !== null ? left + right : null;
    }
    if (ts.isCallExpression(unwrapped)) {
      const member = staticMember(unwrapped.expression);
      if (member?.name === 'join') {
        const array = unwrapExpr(member.object);
        if (!array || !ts.isArrayLiteralExpression(array) || unwrapped.arguments.length > 1) {
          return null;
        }
        const separator =
          unwrapped.arguments.length === 0
            ? ','
            : staticStringValue(unwrapped.arguments[0], seen);
        if (separator === null) {
          return null;
        }
        const values = [];
        for (const element of array.elements) {
          if (ts.isOmittedExpression(element) || ts.isSpreadElement(element)) {
            return null;
          }
          const value = staticStringValue(element, seen);
          if (value === null) {
            return null;
          }
          values.push(value);
        }
        return values.join(separator);
      }
    }
    return null;
  };

  const stringFacts = new Map();

  const stringFactFor = (name) => {
    const existing = stringFacts.get(name);
    if (existing) {
      return existing;
    }
    const fact = { declarations: 0, writes: 0, initializer: undefined };
    stringFacts.set(name, fact);
    return fact;
  };

  const recordStringDeclaration = (target, initializer) => {
    target = unwrapExpr(target);
    if (target && ts.isIdentifier(target)) {
      const fact = stringFactFor(target.text);
      fact.declarations += 1;
      if (fact.declarations === 1) {
        fact.initializer = initializer;
      }
      return;
    }
    if (target && (ts.isObjectBindingPattern(target) || ts.isArrayBindingPattern(target))) {
      for (const element of target.elements) {
        if (ts.isBindingElement(element)) {
          recordStringDeclaration(element.name, undefined);
        }
      }
    }
  };

  const recordStringWrite = (target) => {
    target = unwrapExpr(target);
    if (target && ts.isIdentifier(target)) {
      stringFactFor(target.text).writes += 1;
      return;
    }
    if (target && (ts.isObjectBindingPattern(target) || ts.isArrayBindingPattern(target))) {
      for (const element of target.elements) {
        if (ts.isBindingElement(element)) {
          recordStringWrite(element.name);
        }
      }
      return;
    }
    if (target && ts.isObjectLiteralExpression(target)) {
      for (const property of target.properties) {
        if (ts.isShorthandPropertyAssignment(property)) {
          recordStringWrite(property.name);
        } else if (ts.isPropertyAssignment(property)) {
          recordStringWrite(property.initializer);
        }
      }
      return;
    }
    if (target && ts.isArrayLiteralExpression(target)) {
      for (const element of target.elements) {
        if (!ts.isOmittedExpression(element) && !ts.isSpreadElement(element)) {
          recordStringWrite(element);
        }
      }
    }
  };

  const collectStringFacts = (node) => {
    if (ts.isVariableDeclaration(node)) {
      recordStringDeclaration(node.name, node.initializer);
    }
    if (ts.isParameter(node)) {
      recordStringDeclaration(node.name, undefined);
    }
    if (ts.isBinaryExpression(node) && ts.isAssignmentOperator(node.operatorToken.kind)) {
      recordStringWrite(node.left);
    }
    ts.forEachChild(node, collectStringFacts);
  };

  const seedStableStringValues = () => {
    let changed = true;
    while (changed) {
      changed = false;
      for (const [name, fact] of stringFacts.entries()) {
        if (fact.declarations !== 1 || fact.writes !== 0 || !fact.initializer) {
          continue;
        }
        const value = staticStringValue(fact.initializer);
        if (value !== null && stringValues.get(name) !== value) {
          stringValues.set(name, value);
          changed = true;
        }
      }
    }
  };

  const isMutatingMethodReference = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (unwrapped && ts.isIdentifier(unwrapped)) {
      return mutatorAliases.has(unwrapped.text);
    }
    const member = staticMember(unwrapped);
    return member !== null && MUTATING_ARRAY_METHODS.has(member.name);
  };

  const staticIndexValue = (expr, seen = new Set()) => {
    const argument = unwrapExpr(expr);
    if (!argument) {
      return null;
    }
    if (ts.isNumericLiteral(argument) && Number.isInteger(Number(argument.text))) {
      return Number(argument.text);
    }
    if (
      ts.isPrefixUnaryExpression(argument) &&
      argument.operator === ts.SyntaxKind.MinusToken &&
      ts.isNumericLiteral(argument.operand) &&
      Number.isInteger(Number(argument.operand.text))
    ) {
      return -Number(argument.operand.text);
    }
    if (ts.isStringLiteralLike(argument) && /^\d+$/.test(argument.text)) {
      return Number(argument.text);
    }
    if (ts.isIdentifier(argument)) {
      if (seen.has(argument.text)) {
        return null;
      }
      seen.add(argument.text);
      const stored = valueExprs.get(argument.text);
      return stored ? staticIndexValue(stored, seen) : null;
    }
    return null;
  };

  const staticArrayIndex = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped || !ts.isElementAccessExpression(unwrapped)) {
      return null;
    }
    return staticIndexValue(unwrapped.argumentExpression);
  };

  const storeValueKind = (key, kind) => {
    if (kind === 'factory' || kind === 'requirer') {
      valueKinds.set(key, kind);
    }
  };

  const trackedReferenceKind = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return null;
    }
    const index = staticArrayIndex(unwrapped);
    if (index !== null) {
      const shape = shapeForValue(unwrapped.expression);
      if (shape?.kinds[index] === 'factory' || shape?.kinds[index] === 'requirer') {
        return shape.kinds[index];
      }
      if (shape?.opaque) {
        const dangerous = dangerousShapeKind(shape);
        if (dangerous) return dangerous;
      }
    }
    if (ts.isElementAccessExpression(unwrapped) && index === null) {
      const dangerous = dangerousShapeKind(shapeForValue(unwrapped.expression));
      if (dangerous) return dangerous;
    }
    if (ts.isCallExpression(unwrapped)) {
      const parts = arrayCallParts(unwrapped);
      if (parts?.method === 'at' && (parts.argsUnresolvable || parts.args.length >= 1)) {
        const atIndex = parts.argsUnresolvable || parts.args.length < 1 ? null : staticIndexValue(parts.args[0]);
        if (atIndex !== null) {
          const shape = shapeForValue(parts.object);
          if (shape) {
            const resolved = atIndex >= 0 ? atIndex : shape.kinds.length + atIndex;
            if (shape.kinds[resolved] === 'factory' || shape.kinds[resolved] === 'requirer') {
              return shape.kinds[resolved];
            }
          }
          if (shape?.opaque) {
            const dangerous = dangerousShapeKind(shape);
            if (dangerous) return dangerous;
          }
        }
        if (atIndex === null) {
          const dangerous = dangerousShapeKind(shapeForValue(parts.object));
          if (dangerous) return dangerous;
        }
      }
    }
    const member = staticMember(unwrapped);
    if (member) {
      const resolved = resolveObjectProperty(member.object, member.name);
      const kind = dangerousPropertyKind(resolved);
      if (kind !== null) {
        return kind;
      }
    }
    const key = referenceKey(unwrapped);
    return key === null ? null : valueKinds.get(key) ?? null;
  };

  const classifyBoundCall = (expr) => {
    if (!ts.isCallExpression(expr)) {
      return null;
    }
    const access = staticMember(expr.expression);
    if (access?.name === 'bind') {
      return classifyExpr(access.object);
    }
    return null;
  };

  const classifyIndirectCall = (expr) => {
    const target = applyTarget(expr);
    if (target === UNRESOLVABLE_TARGET) {
      return 'requirer';
    }
    if (!target) {
      return null;
    }
    return classifyExpr(target) === 'factory' ? 'requirer' : null;
  };

  const functionReturnKind = (node) => {
    if (ts.isArrowFunction(node) && !ts.isBlock(node.body)) {
      const kind = classifyExpr(node.body);
      return kind === 'factory' || kind === 'requirer' ? kind : null;
    }
    if (!node.body) {
      return null;
    }
    const kinds = [];
    const collectReturns = (child) => {
      if (child !== node && isFunctionLikeNode(child)) {
        return;
      }
      if (ts.isReturnStatement(child)) {
        const kind = classifyExpr(child.expression);
        if (kind !== null) {
          kinds.push(kind);
        }
        return;
      }
      ts.forEachChild(child, collectReturns);
    };
    collectReturns(node.body);
    if (kinds.length === 0 || kinds.some((kind) => kind !== kinds[0])) {
      return null;
    }
    return kinds[0] === 'factory' || kinds[0] === 'requirer' ? kinds[0] : null;
  };

  const collectReturnExprs = (node) => {
    if (ts.isArrowFunction(node) && !ts.isBlock(node.body)) {
      return [node.body];
    }
    if (!node.body) return [];
    const exprs = [];
    const visit = (child) => {
      if (child !== node && isFunctionLikeNode(child)) return;
      if (ts.isReturnStatement(child) && child.expression) {
        exprs.push(child.expression);
        return;
      }
      ts.forEachChild(child, visit);
    };
    visit(node.body);
    return exprs;
  };

  const functionReturnShapeOf = (node) => {
    const exprs = collectReturnExprs(node);
    if (exprs.length === 0) return null;
    const shapesFromReturn = (expr) => {
      const unwrapped = unwrapExpr(expr);
      if (!unwrapped) return [];
      if (ts.isConditionalExpression(unwrapped)) {
        return [...shapesFromReturn(unwrapped.whenTrue), ...shapesFromReturn(unwrapped.whenFalse)];
      }
      if (isLogicalBinary(unwrapped)) {
        return [...shapesFromReturn(unwrapped.left), ...shapesFromReturn(unwrapped.right)];
      }
      if (ts.isArrayLiteralExpression(unwrapped)) {
        return [shapeFromValue(expr)];
      }
      const known = knownArrayShape(expr);
      return known ? [known] : [];
    };
    const shapes = exprs.flatMap(shapesFromReturn);
    if (shapes.length === 0) return null;
    return mergeArrayShapes(...shapes) ?? null;
  };

  const registerReturnFacts = (key, funcNode) => {
    const kind = functionReturnKind(funcNode);
    if (kind !== null) {
      functionReturns.set(key, kind);
    }
    const shape = functionReturnShapeOf(funcNode);
    if (shape) {
      functionReturnShapes.set(key, shape);
    }
    const retExprs = collectReturnExprs(funcNode);
    if (retExprs.length > 0) {
      functionReturnExprs.set(key, retExprs);
    }
    if (funcNode.parameters) {
      functionParams.set(
        key,
        funcNode.parameters.map((param) => param.name),
      );
    }
  };

  const hasReturnFacts = (key) =>
    functionReturns.has(key) ||
    functionReturnShapes.has(key) ||
    functionReturnExprs.has(key);

  const copyReturnFacts = (targetKey, sourceKey) => {
    if (functionReturns.has(sourceKey)) {
      functionReturns.set(targetKey, functionReturns.get(sourceKey));
    }
    if (functionReturnShapes.has(sourceKey)) {
      functionReturnShapes.set(targetKey, functionReturnShapes.get(sourceKey));
    }
    if (functionReturnExprs.has(sourceKey)) {
      functionReturnExprs.set(targetKey, functionReturnExprs.get(sourceKey));
    }
    if (functionParams.has(sourceKey)) {
      functionParams.set(targetKey, functionParams.get(sourceKey));
    }
  };

  const registerClassMethodReturns = (base, classNode) => {
    const heritage = classNode.heritageClauses?.find(
      (clause) => clause.token === ts.SyntaxKind.ExtendsKeyword,
    );
    const parent = heritage?.types[0] ? referenceKey(heritage.types[0].expression) : null;
    if (parent !== null) {
      classParents.set(base, parent);
    }
    for (const member of classNode.members) {
      if (ts.isConstructorDeclaration(member) && member.body) {
        const registerConstructorAssignment = (node) => {
          if (
            ts.isBinaryExpression(node) &&
            node.operatorToken.kind === ts.SyntaxKind.EqualsToken
          ) {
            const target = staticMember(node.left);
            if (target && target.object.kind === ts.SyntaxKind.ThisKeyword) {
              const key = `${base}.prototype.${target.name}`;
              storeValueKind(key, classifyExpr(node.right));
              registerCallableFacts(key, node.right);
              const assigned = unwrapExpr(node.right);
              if (assigned) {
                valueExprs.set(key, assigned);
                const shape = knownArrayShape(assigned);
                if (shape) {
                  storeArrayShape(key, shape);
                }
                registerObjectArrayShapes(key, assigned);
                registerObjectMethodReturns(key, assigned);
              }
            }
          }
          ts.forEachChild(node, registerConstructorAssignment);
        };
        registerConstructorAssignment(member.body);
      }
      if (!member.name) {
        continue;
      }
      const name = propertyNameText(member.name);
      if (name === null) {
        continue;
      }
      const isStatic = Boolean(
        member.modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.StaticKeyword),
      );
      const key = isStatic ? `${base}.${name}` : `${base}.prototype.${name}`;
      if (ts.isMethodDeclaration(member) || ts.isGetAccessorDeclaration(member)) {
        registerReturnFacts(key, member);
        for (const returned of collectReturnExprs(member)) {
          const assigned = unwrapExpr(returned);
          if (assigned) {
            if (!valueExprs.has(key)) {
              valueExprs.set(key, assigned);
            }
            const shape = knownArrayShape(assigned);
            if (shape) {
              storeArrayShape(key, shape);
            }
            registerObjectArrayShapes(key, assigned);
            registerObjectMethodReturns(key, assigned);
          }
        }
        continue;
      }
      if (!ts.isPropertyDeclaration(member) || !member.initializer) {
        continue;
      }
      const initializer = unwrapExpr(member.initializer);
      storeValueKind(key, classifyExpr(initializer));
      registerCallableFacts(key, initializer);
      if (initializer) {
        valueExprs.set(key, initializer);
        const shape = knownArrayShape(initializer);
        if (shape) {
          storeArrayShape(key, shape);
        }
        registerObjectArrayShapes(key, initializer);
        registerObjectMethodReturns(key, initializer);
      }
      if (isFunctionLikeNode(initializer)) {
        registerReturnFacts(key, initializer);
      }
    }
  };

  const inheritedFactKey = (key) => {
    let current = key;
    const seen = new Set();
    while (!seen.has(current)) {
      seen.add(current);
      if (hasReturnFacts(current) || valueKinds.has(current) || arrayShapes.has(current)) {
        return current;
      }
      const protoMatch = /^(.+)\.prototype\.([^.]+)$/.exec(current);
      if (protoMatch) {
        const parent = classParents.get(protoMatch[1]);
        if (!parent) return current;
        current = `${parent}.prototype.${protoMatch[2]}`;
        continue;
      }
      const staticMatch = /^([^.]+)\.([^.]+)$/.exec(current);
      if (staticMatch) {
        const parent = classParents.get(staticMatch[1]);
        if (!parent) return current;
        current = `${parent}.${staticMatch[2]}`;
        continue;
      }
      return current;
    }
    return key;
  };

  const registerFunctionReturn = (node) => {
    if (ts.isClassDeclaration(node) && node.name) {
      registerClassMethodReturns(node.name.text, node);
      return;
    }
    if (
      ts.isVariableDeclaration(node) &&
      ts.isIdentifier(node.name) &&
      node.initializer &&
      ts.isClassExpression(unwrapExpr(node.initializer))
    ) {
      registerClassMethodReturns(node.name.text, unwrapExpr(node.initializer));
      return;
    }
    if (ts.isFunctionDeclaration(node) && node.name) {
      registerReturnFacts(node.name.text, node);
      return;
    }
    if (
      ts.isVariableDeclaration(node) &&
      ts.isIdentifier(node.name) &&
      node.initializer &&
      isFunctionLikeNode(node.initializer)
    ) {
      registerReturnFacts(node.name.text, node.initializer);
      return;
    }
    if (
      ts.isBinaryExpression(node) &&
      node.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      isFunctionLikeNode(unwrapExpr(node.right))
    ) {
      const key = referenceKey(node.left);
      if (key !== null) {
        registerReturnFacts(key, unwrapExpr(node.right));
      }
    }
  };

  const callableMemberKey = (objectExpr, memberName) => {
    const object = unwrapExpr(objectExpr);
    if (!object) return null;
    if (ts.isNewExpression(object)) {
      const classKey = referenceKey(object.expression);
      return classKey === null ? null : `${classKey}.prototype.${memberName}`;
    }
    const innerMember = staticMember(object);
    if (innerMember) {
      const parentKey = callableMemberKey(innerMember.object, innerMember.name);
      if (parentKey !== null) {
        return `${parentKey}.${memberName}`;
      }
    }
    const objectKey = referenceKey(object);
    if (objectKey === null) return null;
    const instanceClass = classInstances.get(objectKey);
    return instanceClass
      ? `${instanceClass}.prototype.${memberName}`
      : `${objectKey}.${memberName}`;
  };

  const callableReferenceKey = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) return null;
    const member = staticMember(unwrapped);
    if (member) {
      const memberKey = callableMemberKey(member.object, member.name);
      if (memberKey !== null) return memberKey;
    }
    return referenceKey(unwrapped);
  };

  const registerObjectMethodReturns = (base, valueExpr) => {
    const unwrapped = valueExpr ? unwrapExpr(valueExpr) : undefined;
    if (!unwrapped || !ts.isObjectLiteralExpression(unwrapped)) return;
    for (const prop of unwrapped.properties) {
      let name = null;
      let funcNode = null;
      if (ts.isMethodDeclaration(prop) || ts.isGetAccessorDeclaration(prop)) {
        name = propertyNameText(prop.name);
        funcNode = prop;
      } else if (ts.isPropertyAssignment(prop) && isFunctionLikeNode(unwrapExpr(prop.initializer))) {
        name = propertyNameText(prop.name);
        funcNode = unwrapExpr(prop.initializer);
      }
      if (name === null || !funcNode) continue;
      registerReturnFacts(`${base}.${name}`, funcNode);
    }
  };

  const callablePropertyReturnKind = (resolved) => {
    if (!resolved) return null;
    if (resolved.returns === 'factory' || resolved.returns === 'requirer') {
      return resolved.returns;
    }
    if (resolved.callableKey) {
      const kind = functionReturns.get(resolved.callableKey);
      if (kind === 'factory' || kind === 'requirer') return kind;
    }
    if (isFunctionLikeNode(resolved.value)) {
      return functionReturnKind(resolved.value);
    }
    return null;
  };

  const dangerousPropertyKind = (resolved) =>
    resolved?.kind === 'factory' || resolved?.kind === 'requirer'
      ? resolved.kind
      : callablePropertyReturnKind(resolved);

  const classifyFunctionCall = (expr) => {
    if (!ts.isCallExpression(expr)) {
      return null;
    }
    const callee = unwrapExpr(expr.expression);
    if (!callee) {
      return null;
    }
    const access = staticMember(callee);
    const applied = applyTarget(expr);
    if (applied === UNRESOLVABLE_TARGET) {
      return 'requirer';
    }
    if (applied) {
      return callableReturnKind(applied);
    }
    const key = callableReferenceKey(callee);
    if (key !== null) {
      const factKey = inheritedFactKey(key);
      const stored = functionReturns.get(factKey);
      if (stored) {
        return stored;
      }
      for (const returned of functionReturnExprs.get(factKey) ?? []) {
        const kind = callableReturnKind(returned);
        if (kind === 'factory' || kind === 'requirer') {
          return kind === 'factory' ? 'requirer' : kind;
        }
      }
    }
    const calleeKind = classifyCallee(callee);
    if (calleeKind === 'requirer') {
      return 'requirer';
    }
    if (access) {
      return callablePropertyReturnKind(resolveObjectProperty(access.object, access.name));
    }
    return callableReturnKind(callee);
  };

  const storeArrayShape = (key, next) => {
    const previous = arrayShapes.get(key);
    if (previous?.opaque) {
      return previous;
    }
    arrayShapes.set(key, next);
    return next;
  };

  const seedImports = (node) => {
    if (
      ts.isImportDeclaration(node) &&
      node.importClause?.namedBindings &&
      ts.isNamedImports(node.importClause.namedBindings)
    ) {
      const spec = stringLiteralText(node.moduleSpecifier);
      if (spec === 'node:module' || spec === 'module') {
        for (const element of node.importClause.namedBindings.elements) {
          const imported = (element.propertyName ?? element.name).text;
          if (imported === 'createRequire') {
            factories.add(element.name.text);
          }
        }
      }
    }
    ts.forEachChild(node, seedImports);
  };

  const classifyCallee = (expr) => {
    expr = unwrapExpr(expr);
    if (ts.isIdentifier(expr)) {
      const scoped = scopedIdentifierKind(expr);
      if (scoped === 'factory' || scoped === 'requirer') {
        return scoped;
      }
      const bound = enclosingBindingName(expr);
      if (!bound) {
        if (factories.has(expr.text)) {
          return 'factory';
        }
        if (requirers.has(expr.text)) {
          return 'requirer';
        }
      }
      return null;
    }
    if (ts.isConditionalExpression(expr)) {
      return pickDangerousKind(classifyCallee(expr.whenTrue), classifyCallee(expr.whenFalse));
    }
    if (isLogicalBinary(expr)) {
      return pickDangerousKind(classifyCallee(expr.left), classifyCallee(expr.right));
    }
    const member = staticMember(expr);
    if (member) {
      if (member.name === 'createRequire') {
        return 'factory';
      }
      if (member.name === 'require') {
        return 'requirer';
      }
      if (member.name === 'call' || member.name === 'apply') {
        const object = unwrapExpr(member.object);
        if (object && ts.isIdentifier(object) && object.text === 'Reflect') {
          return null;
        }
        const targetKind = classifyExpr(member.object);
        if (targetKind === 'factory' || targetKind === 'requirer') {
          return targetKind;
        }
      }
    }
    const returnedKind = classifyFunctionCall(expr);
    if (returnedKind !== null) {
      return returnedKind;
    }
    const trackedKind = trackedReferenceKind(expr);
    if (trackedKind !== null) {
      return trackedKind;
    }
    if (ts.isCallExpression(expr) && classifyCallee(expr.expression) === 'factory') {
      return 'requirer';
    }
    const boundKind = classifyBoundCall(expr);
    if (boundKind !== null) {
      return boundKind;
    }
    const indirectKind = classifyIndirectCall(expr);
    if (indirectKind !== null) {
      return indirectKind;
    }
    return null;
  };

  const pickDangerousKind = (...kinds) => {
    for (const kind of kinds) {
      if (kind === 'factory' || kind === 'requirer') {
        return kind;
      }
    }
    return null;
  };

  const classifyExpr = (expr) => {
    expr = unwrapExpr(expr);
    if (!expr) {
      return null;
    }
    if (ts.isConditionalExpression(expr)) {
      return pickDangerousKind(classifyExpr(expr.whenTrue), classifyExpr(expr.whenFalse));
    }
    if (isLogicalBinary(expr)) {
      return pickDangerousKind(classifyExpr(expr.left), classifyExpr(expr.right));
    }
    if (ts.isIdentifier(expr)) {
      const scoped = scopedIdentifierKind(expr);
      if (scoped === 'factory' || scoped === 'requirer') {
        return scoped;
      }
      const bound = enclosingBindingName(expr);
      if (!bound) {
        if (factories.has(expr.text)) {
          return 'factory';
        }
        if (requirers.has(expr.text)) {
          return 'requirer';
        }
      }
      return null;
    }
    const trackedKind = trackedReferenceKind(expr);
    if (trackedKind !== null) {
      return trackedKind;
    }
    const boundKind = classifyBoundCall(expr);
    if (boundKind !== null) {
      return boundKind;
    }
    const indirectKind = classifyIndirectCall(expr);
    if (indirectKind !== null) {
      return indirectKind;
    }
    if (ts.isCallExpression(expr)) {
      const directCalleeKind = classifyCallee(expr.expression);
      if (directCalleeKind === 'requirer' || directCalleeKind === 'factory') {
        return directCalleeKind === 'factory' ? 'requirer' : directCalleeKind;
      }
    }
    const returnedKind = classifyFunctionCall(expr);
    if (returnedKind !== null) {
      return returnedKind;
    }
    if (ts.isCallExpression(expr) && classifyCallee(expr.expression) === 'factory') {
      return 'requirer';
    }
    return classifyCallee(expr);
  };

  const kindFromValue = (valueExpr, inheritedKind) => {
    if (!valueExpr || ts.isOmittedExpression(valueExpr) || ts.isSpreadElement(valueExpr)) {
      return inheritedKind;
    }
    return classifyExpr(valueExpr) ?? inheritedKind;
  };

  const shapeFromValue = (valueExpr, seen = new Set()) => {
    const unwrapped = valueExpr ? unwrapExpr(valueExpr) : undefined;
    if (!unwrapped) {
      return opaqueArrayShape();
    }
    if (ts.isArrayLiteralExpression(unwrapped)) {
      const kinds = [];
      const values = [];
      let opaque = false;
      for (const el of unwrapped.elements) {
        if (ts.isOmittedExpression(el)) {
          kinds.push(null);
          values.push(undefined);
          continue;
        }
        if (ts.isSpreadElement(el)) {
          const inner = shapeFromValue(el.expression, seen);
          opaque = opaque || inner.opaque;
          kinds.push(...inner.kinds);
          values.push(...(inner.values ?? inner.kinds.map(() => undefined)));
          continue;
        }
        const kind = classifyExpr(el);
        if (kind === null) {
          opaque = true;
        }
        kinds.push(kind);
        values.push(el);
      }
      return shapeOf(opaque, kinds, values);
    }
    const key = referenceKey(unwrapped);
    if (key !== null) {
      if (seen.has(key)) {
        return opaqueArrayShape();
      }
      seen.add(key);
      const stored = arrayShapes.get(key);
      if (stored) {
        return stored;
      }
      return opaqueArrayShape();
    }
    return opaqueArrayShape();
  };

  const cloneShape = (shape) => {
    if (!shape) {
      return undefined;
    }
    return shapeOf(shape.opaque, [...shape.kinds], [...(shape.values ?? [])]);
  };

  const mergeArrayShapes = (...shapes) => {
    const defined = shapes.filter(Boolean);
    if (defined.length === 0) {
      return undefined;
    }
    const anyOpaque = defined.some((shape) => shape.opaque) || defined.length !== shapes.length;
    if (defined.every((shape) => shape.kinds.length === defined[0].kinds.length)) {
      const mergedKinds = defined[0].kinds.map((_, i) => {
        for (const shape of defined) {
          if (shape.kinds[i] === 'factory' || shape.kinds[i] === 'requirer') return shape.kinds[i];
        }
        return null;
      });
      const mergedValues = [...(defined[0].values ?? [])];
      for (const shape of defined) {
        const values = shape.values ?? [];
        for (let i = 0; i < values.length; i++) {
          if (values[i] && !mergedValues[i]) mergedValues[i] = values[i];
        }
      }
      return { opaque: anyOpaque, kinds: mergedKinds, values: mergedValues };
    }
    return {
      opaque: true,
      kinds: defined.flatMap((shape) => shape.kinds),
      values: defined.flatMap((shape) => shape.values ?? []),
    };
  };

  const shapeValues = (shape) => shape.values ?? shape.kinds.map(() => undefined);

  const normalizedIndex = (index, length) => {
    if (index < 0) {
      return Math.max(0, length + index);
    }
    return Math.min(length, index);
  };

  const isIdentityCallback = (expr) => {
    const fn = unwrapExpr(expr);
    if (!fn || !isFunctionLikeNode(fn) || fn.parameters.length === 0) {
      return false;
    }
    const param = fn.parameters[0].name;
    if (!ts.isIdentifier(param)) {
      return false;
    }
    const returns = collectReturnExprs(fn);
    return (
      returns.length === 1 && ts.isIdentifier(unwrapExpr(returns[0])) && unwrapExpr(returns[0]).text === param.text
    );
  };

  const isArrayWrapOfParamCallback = (expr) => {
    const fn = unwrapExpr(expr);
    if (!fn || !isFunctionLikeNode(fn) || fn.parameters.length === 0) {
      return false;
    }
    const param = fn.parameters[0].name;
    if (!ts.isIdentifier(param)) {
      return false;
    }
    const returns = collectReturnExprs(fn);
    if (returns.length !== 1) {
      return false;
    }
    const arr = unwrapExpr(returns[0]);
    if (!arr || !ts.isArrayLiteralExpression(arr) || arr.elements.length !== 1) {
      return false;
    }
    const element = unwrapExpr(arr.elements[0]);
    return Boolean(element && ts.isIdentifier(element) && element.text === param.text);
  };

  const shapeFromSlice = (source, args) => {
    if (!source) {
      return undefined;
    }
    if (args.length === 0) {
      return cloneShape(source);
    }
    const length = source.kinds.length;
    const rawStart = staticIndexValue(args[0]);
    if (rawStart === null) {
      return shapeOf(true, [...source.kinds], shapeValues(source));
    }
    const rawEnd = args.length < 2 ? length : staticIndexValue(args[1]);
    if (args.length >= 2 && rawEnd === null) {
      return shapeOf(true, [...source.kinds], shapeValues(source));
    }
    const start = normalizedIndex(rawStart, length);
    const end = args.length < 2 ? length : normalizedIndex(rawEnd, length);
    const from = Math.max(start, 0);
    const to = Math.max(start, end);
    return shapeOf(source.opaque, source.kinds.slice(from, to), shapeValues(source).slice(from, to));
  };

  const shapeFromConcat = (source, args) => {
    const kinds = [...(source?.kinds ?? [])];
    const values = [...shapeValues(source ?? { kinds: [], values: [] })];
    let opaque = Boolean(source?.opaque || !source);
    for (const arg of args) {
      const value = ts.isSpreadElement(arg) ? arg.expression : arg;
      const unwrappedValue = unwrapExpr(value);
      const argShape = shapeForValue(value) ?? (unwrappedValue && ts.isArrayLiteralExpression(unwrappedValue) ? shapeFromValue(value) : undefined);
      if (argShape && (argShape.kinds.length > 0 || (unwrappedValue && ts.isArrayLiteralExpression(unwrappedValue)))) {
        opaque = opaque || argShape.opaque;
        kinds.push(...argShape.kinds);
        values.push(...shapeValues(argShape));
        continue;
      }
      const kind = classifyExpr(value);
      if (kind === null) {
        opaque = true;
      }
      kinds.push(kind);
      values.push(value);
    }
    return shapeOf(opaque, kinds, values);
  };

  const callbackReturnExprs = (expr) => {
    const fn = unwrapExpr(expr);
    if (!fn || !isFunctionLikeNode(fn)) {
      return [];
    }
    return collectReturnExprs(fn);
  };

  const shapeFromMappedCallback = (source, callback) => {
    const returns = callback ? callbackReturnExprs(callback) : [];
    if (returns.length === 0) {
      return opaqueArrayShape();
    }
    const mappedKind = pickDangerousKind(...returns.map((ret) => classifyExpr(ret)));
    const length = Math.max(source?.kinds.length ?? 0, returns.length, 1);
    const kinds = Array.from({ length }, (_, i) => classifyExpr(returns[i]) ?? mappedKind);
    const values = Array.from({ length }, (_, i) => returns[i] ?? returns[0]);
    const extra = returns.slice(length);
    return shapeOf(true, kinds, [...values, ...extra]);
  };

  const shapeFromMap = (source, args) => {
    if (!source) {
      return undefined;
    }
    if (args.length > 0 && isIdentityCallback(args[0])) {
      return cloneShape(source);
    }
    return shapeFromMappedCallback(source, args[0]);
  };

  const shapeFromFilter = (source) => {
    if (!source) {
      return undefined;
    }
    return shapeOf(true, [...source.kinds], shapeValues(source));
  };

  const flattenShapeOnce = (source) => {
    const kinds = [];
    const values = [];
    let opaque = source.opaque;
    const srcValues = shapeValues(source);
    for (let i = 0; i < source.kinds.length; i++) {
      const value = srcValues[i];
      const inner = value
        ? (knownArrayShape(value) ??
          (ts.isArrayLiteralExpression(unwrapExpr(value)) ? shapeFromValue(value) : undefined))
        : undefined;
      if (inner) {
        opaque = opaque || inner.opaque;
        kinds.push(...inner.kinds);
        values.push(...shapeValues(inner));
        continue;
      }
      kinds.push(source.kinds[i]);
      values.push(value);
    }
    return shapeOf(opaque, kinds, values);
  };

  const shapeFromFlatMap = (source, args) => {
    if (!source) {
      return undefined;
    }
    if (args[0] && isArrayWrapOfParamCallback(args[0])) {
      return cloneShape(source);
    }
    return shapeFromFlat(shapeFromMap(source, args), []);
  };

  const shapeFromToReversed = (source) => {
    if (!source) {
      return undefined;
    }
    return shapeOf(source.opaque, [...source.kinds].reverse(), [...shapeValues(source)].reverse());
  };

  const shapeFromWith = (source, args) => {
    if (!source) {
      return undefined;
    }
    const next = cloneShape(source);
    const index = args[0] ? staticIndexValue(args[0]) : null;
    if (index === null || args.length < 2) {
      next.opaque = true;
      return next;
    }
    const resolved = index >= 0 ? index : next.kinds.length + index;
    if (resolved < 0) {
      next.opaque = true;
      return next;
    }
    next.kinds[resolved] = classifyExpr(args[1]);
    const values = shapeValues(next);
    values[resolved] = args[1];
    next.values = values;
    if (next.kinds[resolved] === null) {
      next.opaque = true;
    }
    return next;
  };

  const shapeFromToSpliced = (source, args) => {
    if (!source) {
      return undefined;
    }
    const next = cloneShape(source);
    if (args.length === 0) {
      return next;
    }
    const start = staticIndexValue(args[0]);
    if (start === null) {
      next.opaque = true;
      return next;
    }
    const deleteCount = args.length < 2 ? next.kinds.length - start : staticIndexValue(args[1]);
    if (args.length >= 2 && deleteCount === null) {
      next.opaque = true;
      return next;
    }
    const insert = args.slice(2);
    const insertKinds = insert.map((arg) => classifyExpr(arg));
    const from = normalizedIndex(start, next.kinds.length);
    const del = args.length < 2 ? Math.max(0, next.kinds.length - from) : Math.max(0, deleteCount);
    next.kinds.splice(from, del, ...insertKinds);
    const values = shapeValues(next);
    values.splice(from, del, ...insert);
    next.values = values;
    if (insertKinds.some((kind) => kind === null)) {
      next.opaque = true;
    }
    return next;
  };

  const shapeFromFlat = (source, args) => {
    if (!source) {
      return undefined;
    }
    let depth = 1;
    if (args.length > 0) {
      const parsed = staticIndexValue(args[0]);
      depth = parsed === null ? Number.POSITIVE_INFINITY : parsed;
    }
    let current = cloneShape(source);
    let remaining = Number.isFinite(depth) ? depth : Number.POSITIVE_INFINITY;
    const safety = 4096;
    let steps = 0;
    while (remaining > 0 && steps < safety) {
      const next = flattenShapeOnce(current);
      remaining -= 1;
      steps += 1;
      if (
        next.kinds.length === current.kinds.length &&
        next.values.every((value, i) => value === current.values[i])
      ) {
        return next;
      }
      current = next;
    }
    if (!Number.isFinite(depth)) {
      current.opaque = true;
    }
    return current;
  };

  const shapeFromArrayFrom = (args) => {
    if (args.length === 0) {
      return opaqueArrayShape();
    }
    const source = shapeForValue(args[0]) ?? shapeFromValue(args[0]);
    if (!source) {
      return opaqueArrayShape();
    }
    if (args.length > 1) {
      if (isIdentityCallback(args[1])) {
        return cloneShape(source);
      }
      return shapeFromMappedCallback(source, args[1]);
    }
    return cloneShape(source);
  };

  const shapeFromArrayItems = (items, unresolvable = false) => {
    const kinds = [];
    const values = [];
    let opaque = unresolvable;
    for (const arg of items) {
      if (!arg) {
        kinds.push(null);
        values.push(undefined);
        continue;
      }
      const kind = classifyExpr(arg);
      if (kind === null) {
        opaque = true;
      }
      kinds.push(kind);
      values.push(arg);
    }
    return shapeOf(opaque, kinds, values);
  };

  const isNumericLengthArg = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    if (ts.isNumericLiteral(unwrapped)) {
      return true;
    }
    return (
      ts.isPrefixUnaryExpression(unwrapped) &&
      (unwrapped.operator === ts.SyntaxKind.MinusToken || unwrapped.operator === ts.SyntaxKind.PlusToken) &&
      ts.isNumericLiteral(unwrapped.operand)
    );
  };

  const shapeFromArrayConstructor = (args) => {
    const list = args ?? [];
    const flat = flattenCallArguments(list);
    if (flat.items.length === 1 && !flat.unresolvable && flat.items[0] && isNumericLengthArg(flat.items[0])) {
      return opaqueArrayShape();
    }
    return shapeFromArrayItems(flat.items, flat.unresolvable);
  };

  const shapeForValue = (valueExpr) => {
    const unwrapped = valueExpr ? unwrapExpr(valueExpr) : undefined;
    if (!unwrapped) {
      return undefined;
    }
    if (ts.isArrayLiteralExpression(unwrapped)) {
      return shapeFromValue(unwrapped);
    }
    if (ts.isConditionalExpression(unwrapped)) {
      return mergeArrayShapes(shapeForValue(unwrapped.whenTrue), shapeForValue(unwrapped.whenFalse));
    }
    if (isLogicalBinary(unwrapped)) {
      return mergeArrayShapes(shapeForValue(unwrapped.left), shapeForValue(unwrapped.right));
    }
    if (ts.isCallExpression(unwrapped)) {
      const parts = arrayCallParts(unwrapped);
      if (parts?.method === 'slice') {
        return shapeFromSlice(shapeForValue(parts.object), parts.args);
      }
      if (parts?.method === 'concat') {
        const shape = shapeFromConcat(shapeForValue(parts.object), parts.args);
        if (shape && parts.argsUnresolvable) {
          return shapeOf(true, shape.kinds, shapeValues(shape));
        }
        return shape;
      }
      if (parts?.method === 'map') {
        return shapeFromMap(shapeForValue(parts.object), parts.args);
      }
      if (parts?.method === 'filter') {
        return shapeFromFilter(shapeForValue(parts.object));
      }
      if (parts?.method === 'flat') {
        return shapeFromFlat(shapeForValue(parts.object), parts.args);
      }
      if (parts?.method === 'flatMap') {
        return shapeFromFlatMap(shapeForValue(parts.object), parts.args);
      }
      if (parts?.method === 'toReversed') {
        return shapeFromToReversed(shapeForValue(parts.object));
      }
      if (parts?.method === 'toSorted') {
        return shapeFromFilter(shapeForValue(parts.object));
      }
      if (parts?.method === 'toSpliced') {
        return shapeFromToSpliced(shapeForValue(parts.object), parts.args);
      }
      if (parts?.method === 'with') {
        return shapeFromWith(shapeForValue(parts.object), parts.args);
      }
      const inv = invocationOf(unwrapped);
      if (inv && isArrayFromCallee(inv.callee)) {
        return shapeFromArrayFrom(inv.args);
      }
      if (inv && isArrayOfCallee(inv.callee)) {
        return shapeFromArrayItems(inv.args, inv.unresolvable);
      }
      if (inv && isArrayConstructorCallee(inv.callee)) {
        if (inv.args.length === 1 && !inv.unresolvable && inv.args[0] && isNumericLengthArg(inv.args[0])) {
          return opaqueArrayShape();
        }
        return shapeFromArrayItems(inv.args, inv.unresolvable);
      }
      if (inv && isReflectConstructCallee(inv.callee) && inv.args[0] && isArrayConstructorCallee(inv.args[0])) {
        const constructed = inv.args[1] ? expandSpread(inv.args[1]) : { items: [], complete: true, dropped: false };
        if (constructed === null) {
          return opaqueArrayShape();
        }
        return shapeFromArrayItems(constructed.items, !constructed.complete || constructed.dropped);
      }
      const callee = unwrapExpr(unwrapped.expression);
      if (isFunctionLikeNode(callee)) {
        return functionReturnShapeOf(callee);
      }
      const funcKey = callableReferenceKey(callee);
      if (funcKey) return functionReturnShapes.get(inheritedFactKey(funcKey));
      return undefined;
    }
    if (ts.isNewExpression(unwrapped) && isArrayConstructorCallee(unwrapped.expression)) {
      return shapeFromArrayConstructor(unwrapped.arguments ?? []);
    }
    const member = staticMember(unwrapped);
    if (member) {
      const propertyKey = callableMemberKey(member.object, member.name);
      if (propertyKey !== null) {
        const stored = arrayShapes.get(inheritedFactKey(propertyKey));
        if (stored) {
          return stored;
        }
      }
      const resolved = resolveObjectProperty(member.object, member.name);
      if (resolved?.shape) {
        return resolved.shape;
      }
    }
    const key = referenceKey(unwrapped);
    if (key !== null && ts.isIdentifier(unwrapped)) {
      const decl = enclosingBindingName(unwrapped);
      if (decl) {
        return scopedArrayShapes.has(decl) ? scopedArrayShapes.get(decl) : undefined;
      }
    }
    return key === null ? undefined : arrayShapes.get(key);
  };

  const knownArrayShape = (valueExpr) => shapeForValue(valueExpr);

  const isOpaqueObjectSource = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return true;
    }
    if (ts.isObjectLiteralExpression(unwrapped) || ts.isArrayLiteralExpression(unwrapped)) {
      return false;
    }
    if (isObjectAssignCall(unwrapped)) {
      return objectAssignArguments(unwrapped) === null;
    }
    if (ts.isCallExpression(unwrapped)) {
      const created = invocationOf(unwrapped);
      if (created && isObjectCreateCallee(created.callee)) {
        return false;
      }
      if (returnExprsForCallable(unwrapped.expression).length > 0) {
        return false;
      }
      const funcKey = callableReferenceKey(unwrapExpr(unwrapped.expression));
      if (funcKey && hasReturnFacts(inheritedFactKey(funcKey))) {
        return false;
      }
      return true;
    }
    if (ts.isNewExpression(unwrapped)) {
      const classKey = referenceKey(unwrapped.expression);
      if (classKey === null) {
        return true;
      }
      const prefixes = [`${classKey}.`, `${classKey}.prototype.`];
      for (const factKey of [...valueExprs.keys(), ...functionReturns.keys(), ...arrayShapes.keys()]) {
        if (prefixes.some((prefix) => factKey.startsWith(prefix))) {
          return false;
        }
      }
      return true;
    }
    const key = referenceKey(unwrapped);
    if (key === null) {
      return true;
    }
    if (
      valueExprs.has(key) ||
      valueKinds.has(key) ||
      arrayShapes.has(key) ||
      hasReturnFacts(key) ||
      classInstances.has(key)
    ) {
      return false;
    }
    const prefix = `${key}.`;
    for (const factKey of [...valueExprs.keys(), ...valueKinds.keys(), ...functionReturns.keys(), ...arrayShapes.keys()]) {
      if (factKey.startsWith(prefix)) {
        return false;
      }
    }
    return true;
  };

  const isNullProtoExpr = (expr) => {
    const unwrapped = unwrapExpr(expr);
    return Boolean(unwrapped && unwrapped.kind === ts.SyntaxKind.NullKeyword);
  };

  const objectPrototypeProperty = (key) => {
    const factKey = `Object.prototype.${key}`;
    const shape = arrayShapes.get(factKey);
    const kind = valueKinds.get(factKey);
    const storedFactValue = valueExprs.get(factKey);
    return shape || kind || hasReturnFacts(factKey) || storedFactValue
      ? { value: storedFactValue, kind: kind ?? null, shape, callableKey: factKey }
      : undefined;
  };

  const indexedElement = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return null;
    }
    let shape;
    let index = null;
    if (ts.isElementAccessExpression(unwrapped)) {
      index = staticIndexValue(unwrapped.argumentExpression);
      shape = shapeForValue(unwrapped.expression);
    } else {
      const parts = arrayCallParts(unwrapped);
      if (parts?.method === 'at' && (parts.argsUnresolvable || parts.args.length >= 1)) {
        index = parts.argsUnresolvable || parts.args.length < 1 ? null : staticIndexValue(parts.args[0]);
        shape = shapeForValue(parts.object);
      }
    }
    if (!shape) {
      return null;
    }
    const candidates = shapeValues(shape).filter(Boolean);
    if (index === null || shape.opaque) {
      const resolved = index === null ? null : index >= 0 ? index : shape.kinds.length + index;
      const trusted =
        !shape.opaque && resolved !== null ? shapeValues(shape)[resolved] : undefined;
      return {
        opaque: true,
        kind: resolved !== null ? shape.kinds[resolved] : undefined,
        value: trusted,
        candidates,
      };
    }
    const resolved = index >= 0 ? index : shape.kinds.length + index;
    return {
      opaque: false,
      kind: shape.kinds[resolved],
      value: shapeValues(shape)[resolved],
      candidates,
    };
  };

  const resolveObjectProperty = (valueExpr, key, seen = new Set()) => {
    const unwrapped = valueExpr ? unwrapExpr(valueExpr) : undefined;
    if (!unwrapped || seen.has(unwrapped)) return undefined;
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    if (unwrapped && ts.isConditionalExpression(unwrapped)) {
      let fallback;
      for (const branch of [unwrapped.whenTrue, unwrapped.whenFalse]) {
        const resolved = resolveObjectProperty(branch, key, nextSeen);
        if (!resolved) continue;
        if (dangerousPropertyKind(resolved) !== null) return resolved;
        if (!fallback) fallback = resolved;
      }
      return fallback;
    }
    if (unwrapped && isLogicalBinary(unwrapped)) {
      let fallback;
      for (const branch of [unwrapped.left, unwrapped.right]) {
        const resolved = resolveObjectProperty(branch, key, nextSeen);
        if (!resolved) continue;
        if (dangerousPropertyKind(resolved) !== null) return resolved;
        if (!fallback) fallback = resolved;
      }
      return fallback;
    }
    const indexed = indexedElement(unwrapped);
    if (indexed) {
      if (indexed.opaque) {
        let fallback;
        for (const candidate of indexed.candidates) {
          const resolved = resolveObjectProperty(candidate, key, nextSeen);
          if (!resolved) continue;
          if (dangerousPropertyKind(resolved) !== null) return resolved;
          if (!fallback) fallback = resolved;
        }
        if (fallback) return fallback;
        if (LOADERISH_PROPERTIES.has(key)) {
          return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
        }
      }
      if (indexed.value) {
        return resolveObjectProperty(indexed.value, key, nextSeen);
      }
    }
    if (unwrapped && ts.isCallExpression(unwrapped)) {
      if (isObjectAssignCall(unwrapped)) {
        const assignArgs = objectAssignArguments(unwrapped);
        if (assignArgs === null) {
          if (LOADERISH_PROPERTIES.has(key)) {
            return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
          }
          return { value: undefined, kind: 'requirer', shape: opaqueArrayShape(), callableKey: null };
        }
        let fallback;
        let opaqueSource = false;
        for (const arg of assignArgs ?? []) {
          const sources = ts.isSpreadElement(arg)
            ? (expandSpread(arg.expression)?.items ?? [arg.expression])
            : [arg];
          for (const source of sources) {
            const resolved = resolveObjectProperty(source, key, nextSeen);
            if (resolved) {
              if (dangerousPropertyKind(resolved) !== null) return resolved;
              fallback = resolved;
              opaqueSource = false;
              continue;
            }
            if (isOpaqueObjectSource(source)) {
              opaqueSource = true;
            }
          }
        }
        if (opaqueSource && LOADERISH_PROPERTIES.has(key)) {
          return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
        }
        return fallback;
      }
      const created = invocationOf(unwrapped);
      if (created && isObjectCreateCallee(created.callee)) {
        if (created.unresolvable) {
          if (LOADERISH_PROPERTIES.has(key)) {
            return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
          }
          return undefined;
        }
        const protoExpr = created.args[0];
        const descriptorsExpr = created.args[1];
        if (descriptorsExpr) {
          const fromDescriptors = resolveDescriptorMapProperty(descriptorsExpr, key);
          if (fromDescriptors) {
            return fromDescriptors;
          }
          if (resolvedOpaqueSource(descriptorsExpr) && LOADERISH_PROPERTIES.has(key)) {
            return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
          }
        }
        if (!protoExpr || isNullProtoExpr(protoExpr)) {
          return undefined;
        }
        const fromProto = resolveObjectProperty(protoExpr, key, nextSeen);
        if (fromProto) {
          return fromProto;
        }
        if (isOpaqueObjectSource(protoExpr) && LOADERISH_PROPERTIES.has(key)) {
          return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
        }
        return undefined;
      }
      if (created && isObjectDefinePropertyCallee(created.callee)) {
        if (created.unresolvable || created.args.length < 3) {
          if (LOADERISH_PROPERTIES.has(key)) {
            return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
          }
          return undefined;
        }
        const targetExpr = created.args[0];
        const propName = staticStringValue(created.args[1]);
        if (propName === key) {
          const fromDescriptor = interpretDescriptor(created.args[2]);
          if (fromDescriptor) {
            return fromDescriptor;
          }
          if (isOpaqueObjectSource(created.args[2]) && LOADERISH_PROPERTIES.has(key)) {
            return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
          }
          const targetKey = referenceKey(targetExpr);
          if (targetKey && propName) {
            const factKey = `${targetKey}.${propName}`;
            const kind = valueKinds.get(factKey);
            const shape = arrayShapes.get(factKey);
            const storedFactValue = valueExprs.get(factKey);
            if (kind || shape || hasReturnFacts(factKey) || storedFactValue) {
              return { value: storedFactValue, kind: kind ?? null, shape, callableKey: factKey };
            }
          }
        }
        const fromTarget = resolveObjectProperty(targetExpr, key, nextSeen);
        if (fromTarget) {
          return fromTarget;
        }
        return undefined;
      }
      if (created && isObjectDefinePropertiesCallee(created.callee)) {
        if (created.unresolvable || created.args.length < 2) {
          if (LOADERISH_PROPERTIES.has(key)) {
            return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
          }
          return undefined;
        }
        const targetExpr = created.args[0];
        const fromDescriptors = resolveDescriptorMapProperty(created.args[1], key);
        if (fromDescriptors) {
          return fromDescriptors;
        }
        const fromTarget = resolveObjectProperty(targetExpr, key, nextSeen);
        if (fromTarget) {
          return fromTarget;
        }
        if (isOpaqueObjectSource(created.args[1]) && LOADERISH_PROPERTIES.has(key)) {
          return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
        }
        return undefined;
      }
      if (created && isObjectSetPrototypeOfCallee(created.callee)) {
        if (created.unresolvable || created.args.length < 2) {
          if (LOADERISH_PROPERTIES.has(key)) {
            return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
          }
          return undefined;
        }
        const fromTarget = resolveObjectProperty(created.args[0], key, nextSeen);
        if (fromTarget) {
          return fromTarget;
        }
        const fromProto = resolveObjectProperty(created.args[1], key, nextSeen);
        if (fromProto) {
          return fromProto;
        }
        if (isOpaqueObjectSource(created.args[1]) && LOADERISH_PROPERTIES.has(key)) {
          return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
        }
        return undefined;
      }
      const returnExprs = returnExprsForCallable(unwrapped.expression);
      let fallback;
      for (const returnExpr of returnExprs) {
        const resolved = resolveObjectProperty(returnExpr, key, nextSeen);
        if (!resolved) continue;
        if (dangerousPropertyKind(resolved) !== null) return resolved;
        if (!fallback) fallback = resolved;
      }
      return fallback;
    }
    if (unwrapped && ts.isObjectLiteralExpression(unwrapped)) {
      let resolved;
      let opaqueSpread = false;
      for (const property of unwrapped.properties) {
        if (ts.isSpreadAssignment(property)) {
          const spread = resolveObjectProperty(property.expression, key, nextSeen);
          if (spread) {
            resolved = spread;
            opaqueSpread = false;
          } else if (isOpaqueObjectSource(property.expression)) {
            opaqueSpread = true;
          }
          continue;
        }
        let propertyKey = null;
        let propertyValue;
        if (ts.isShorthandPropertyAssignment(property)) {
          propertyKey = property.name.text;
          propertyValue = property.name;
        } else if (ts.isPropertyAssignment(property)) {
          propertyKey = propertyNameText(property.name);
          propertyValue = property.initializer;
        } else if (ts.isMethodDeclaration(property) || ts.isGetAccessorDeclaration(property)) {
          propertyKey = propertyNameText(property.name);
          propertyValue = property;
        }
        if (propertyKey === key) {
          resolved = {
            value: propertyValue,
            kind: classifyExpr(propertyValue),
            shape: knownArrayShape(propertyValue),
            callableKey: null,
          };
          opaqueSpread = false;
        }
      }
      if (opaqueSpread && LOADERISH_PROPERTIES.has(key)) {
        return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
      }
      if (resolved) {
        return resolved;
      }
      return objectPrototypeProperty(key);
    }
    const member = staticMember(unwrapped);
    if (member) {
      const parent = resolveObjectProperty(member.object, member.name, nextSeen);
      if (parent?.value) {
        const nested = resolveObjectProperty(parent.value, key, nextSeen);
        if (nested) return nested;
      }
      if (parent?.callableKey) {
        const nestedKey = inheritedFactKey(`${parent.callableKey}.${key}`);
        const shape = arrayShapes.get(nestedKey);
        const kind = valueKinds.get(nestedKey);
        if (shape || kind || hasReturnFacts(nestedKey)) {
          return { value: undefined, kind: kind ?? null, shape, callableKey: nestedKey };
        }
        let fallback;
        for (const returned of functionReturnExprs.get(parent.callableKey) ?? []) {
          const nested = resolveObjectProperty(returned, key, nextSeen);
          if (!nested) continue;
          if (dangerousPropertyKind(nested) !== null) return nested;
          if (!fallback) fallback = nested;
        }
        if (fallback) return fallback;
      }
    }
    const sourceKey = referenceKey(unwrapped);
    const storedValue = sourceKey === null ? undefined : valueExprs.get(sourceKey);
    if (storedValue && storedValue !== unwrapped) {
      const resolved = resolveObjectProperty(storedValue, key, nextSeen);
      if (resolved) return resolved;
    }
    if (sourceKey !== null && prototypeExprs.has(sourceKey)) {
      const protoExpr = prototypeExprs.get(sourceKey);
      const fromProto = resolveObjectProperty(protoExpr, key, nextSeen);
      if (fromProto) {
        return fromProto;
      }
      if (isOpaqueObjectSource(protoExpr) && LOADERISH_PROPERTIES.has(key)) {
        return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
      }
    }
    const propertyKey = callableMemberKey(unwrapped, key);
    if (propertyKey !== null) {
      const factKey = inheritedFactKey(propertyKey);
      const shape = arrayShapes.get(factKey);
      const kind = valueKinds.get(factKey);
      const storedFactValue = valueExprs.get(factKey);
      if (shape || kind || hasReturnFacts(factKey) || storedFactValue) {
        return { value: storedFactValue, kind: kind ?? null, shape, callableKey: factKey };
      }
    }
    return objectPrototypeProperty(key);
  };

  const returnExprsForCallable = (valueExpr) => {
    const unwrapped = valueExpr ? unwrapExpr(valueExpr) : undefined;
    if (!unwrapped) return [];
    if (isFunctionLikeNode(unwrapped)) {
      return collectReturnExprs(unwrapped);
    }
    const access = staticMember(unwrapped);
    if (access?.name === 'call' || access?.name === 'apply') {
      return returnExprsForCallable(access.object);
    }
    const callableKey = callableReferenceKey(unwrapped);
    if (callableKey === null) return [];
    return functionReturnExprs.get(inheritedFactKey(callableKey)) ?? [];
  };

  const callableReturnKind = (valueExpr, seen = new Set()) => {
    const unwrapped = valueExpr ? unwrapExpr(valueExpr) : undefined;
    if (!unwrapped || seen.has(unwrapped)) return null;
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    if (isFunctionLikeNode(unwrapped)) {
      return functionReturnKind(unwrapped);
    }
    if (ts.isConditionalExpression(unwrapped)) {
      return (
        callableReturnKind(unwrapped.whenTrue, nextSeen) ??
        callableReturnKind(unwrapped.whenFalse, nextSeen)
      );
    }
    if (
      ts.isBinaryExpression(unwrapped) &&
      (unwrapped.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken ||
        unwrapped.operatorToken.kind === ts.SyntaxKind.BarBarToken ||
        unwrapped.operatorToken.kind === ts.SyntaxKind.QuestionQuestionToken)
    ) {
      return (
        callableReturnKind(unwrapped.left, nextSeen) ??
        callableReturnKind(unwrapped.right, nextSeen)
      );
    }
    if (ts.isCallExpression(unwrapped)) {
      const access = staticMember(unwrapped.expression);
      if (access?.name === 'bind') {
        return callableReturnKind(access.object, nextSeen);
      }
      for (const returned of returnExprsForCallable(unwrapped.expression)) {
        const kind = callableReturnKind(returned, nextSeen);
        if (kind === 'factory' || kind === 'requirer') return kind;
      }
      const invoked = classifyFunctionCall(unwrapped);
      if (invoked === 'factory' || invoked === 'requirer') {
        return invoked;
      }
      return null;
    }
    const member = staticMember(unwrapped);
    if (member) {
      const resolved = resolveObjectProperty(member.object, member.name);
      const kind = callablePropertyReturnKind(resolved);
      if (kind !== null) return kind;
      if (resolved?.value) return callableReturnKind(resolved.value, nextSeen);
    }
    const callableKey = callableReferenceKey(unwrapped);
    if (callableKey === null) return null;
    return functionReturns.get(inheritedFactKey(callableKey)) ?? null;
  };

  const registerCallableFacts = (targetKey, valueExpr, seen = new Set()) => {
    const unwrapped = valueExpr ? unwrapExpr(valueExpr) : undefined;
    if (!unwrapped || seen.has(unwrapped)) return;
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    if (isFunctionLikeNode(unwrapped)) {
      registerReturnFacts(targetKey, unwrapped);
      return;
    }
    if (ts.isConditionalExpression(unwrapped)) {
      registerCallableFacts(targetKey, unwrapped.whenTrue, nextSeen);
      registerCallableFacts(targetKey, unwrapped.whenFalse, nextSeen);
      return;
    }
    if (
      ts.isBinaryExpression(unwrapped) &&
      (unwrapped.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken ||
        unwrapped.operatorToken.kind === ts.SyntaxKind.BarBarToken ||
        unwrapped.operatorToken.kind === ts.SyntaxKind.QuestionQuestionToken)
    ) {
      registerCallableFacts(targetKey, unwrapped.left, nextSeen);
      registerCallableFacts(targetKey, unwrapped.right, nextSeen);
      return;
    }
    if (ts.isCallExpression(unwrapped)) {
      const access = staticMember(unwrapped.expression);
      if (access?.name === 'bind') {
        registerCallableFacts(targetKey, access.object, nextSeen);
        return;
      }
      for (const returned of returnExprsForCallable(unwrapped.expression)) {
        registerCallableFacts(targetKey, returned, nextSeen);
      }
      return;
    }
    const member = staticMember(unwrapped);
    if (member) {
      const resolved = resolveObjectProperty(member.object, member.name);
      if (resolved?.callableKey) copyReturnFacts(targetKey, resolved.callableKey);
      if (resolved?.value) registerCallableFacts(targetKey, resolved.value, nextSeen);
    }
    const sourceKey = callableReferenceKey(unwrapped);
    if (sourceKey !== null && sourceKey !== targetKey) {
      copyReturnFacts(targetKey, inheritedFactKey(sourceKey));
    }
  };

  const copyObjectArrayShapes = (targetBase, sourceBase) => {
    const prefix = `${sourceBase}.`;
    for (const [key, shape] of [...arrayShapes.entries()]) {
      if (key.startsWith(prefix)) {
        storeArrayShape(`${targetBase}.${key.slice(prefix.length)}`, shape);
      }
    }
    for (const [key, kind] of [...valueKinds.entries()]) {
      if (key.startsWith(prefix)) {
        storeValueKind(`${targetBase}.${key.slice(prefix.length)}`, kind);
      }
    }
    for (const [key, kind] of [...functionReturns.entries()]) {
      if (key.startsWith(prefix)) {
        functionReturns.set(`${targetBase}.${key.slice(prefix.length)}`, kind);
      }
    }
    for (const [key, shape] of [...functionReturnShapes.entries()]) {
      if (key.startsWith(prefix)) {
        functionReturnShapes.set(`${targetBase}.${key.slice(prefix.length)}`, shape);
      }
    }
    for (const [key, exprs] of [...functionReturnExprs.entries()]) {
      if (key.startsWith(prefix)) {
        functionReturnExprs.set(`${targetBase}.${key.slice(prefix.length)}`, exprs);
      }
    }
    for (const [key, className] of [...classInstances.entries()]) {
      if (key.startsWith(prefix)) {
        classInstances.set(`${targetBase}.${key.slice(prefix.length)}`, className);
      }
    }
  };

  const registerObjectArrayShapes = (base, valueExpr, seen = new Set()) => {
    const unwrapped = valueExpr ? unwrapExpr(valueExpr) : undefined;
    if (!unwrapped || !ts.isObjectLiteralExpression(unwrapped) || seen.has(unwrapped)) {
      return;
    }
    seen.add(unwrapped);
    for (const property of unwrapped.properties) {
      if (ts.isSpreadAssignment(property)) {
        const spread = unwrapExpr(property.expression);
        const sourceBase = referenceKey(spread);
        if (sourceBase !== null) {
          copyObjectArrayShapes(base, sourceBase);
        }
        registerObjectArrayShapes(base, spread, seen);
        continue;
      }
      let key = null;
      let propertyValue;
      if (ts.isShorthandPropertyAssignment(property)) {
        key = property.name.text;
        propertyValue = property.name;
      } else if (ts.isPropertyAssignment(property)) {
        key = propertyNameText(property.name);
        propertyValue = property.initializer;
      }
      if (key === null || propertyValue === undefined) {
        continue;
      }
      const propertyBase = `${base}.${key}`;
      valueExprs.set(propertyBase, propertyValue);
      bindIndirectAliases(propertyBase, propertyValue);
      storeValueKind(propertyBase, classifyExpr(propertyValue));
      registerCallableFacts(propertyBase, propertyValue);
      const unwrappedProperty = unwrapExpr(propertyValue);
      if (unwrappedProperty && ts.isNewExpression(unwrappedProperty)) {
        const classKey = referenceKey(unwrappedProperty.expression);
        if (classKey !== null) classInstances.set(propertyBase, classKey);
      }
      const shape = knownArrayShape(propertyValue);
      if (shape) {
        storeArrayShape(propertyBase, shape);
        continue;
      }
      const sourceBase = referenceKey(propertyValue);
      if (sourceBase !== null) {
        copyObjectArrayShapes(propertyBase, sourceBase);
      }
      registerObjectMethodReturns(propertyBase, propertyValue);
      registerObjectArrayShapes(propertyBase, propertyValue, seen);
      if (unwrappedProperty && ts.isCallExpression(unwrappedProperty)) {
        for (const returned of returnExprsForCallable(unwrappedProperty.expression)) {
          registerObjectMethodReturns(propertyBase, returned);
          registerObjectArrayShapes(propertyBase, returned, seen);
        }
      }
    }
  };

  const bindPattern = (name, inheritedKind, valueExpr, shapeOverride, callableKeyOverride) => {
    if (ts.isIdentifier(name)) {
      const kind = kindFromValue(valueExpr, inheritedKind);
      const scopedKind = kind === 'factory' || kind === 'requirer' ? kind : null;
      if (scopedKind) {
        scopedBindingKinds.set(name, scopedKind);
      }
      const isParamBinding = Boolean(parameterFromName(name));
      if (scopedKind && isParamBinding) {
        const param = parameterFromName(name);
        if (param?.parent && isFunctionLikeNode(param.parent)) {
          const funcNode = param.parent;
          const funcKey = funcNode.name ? referenceKey(funcNode.name) : callableReferenceKey(funcNode);
          if (funcKey !== null) {
            paramBindingKinds.set(`${funcKey}#${name.text}`, scopedKind);
          }
        }
      }
      if (
        scopedKind &&
        name.parent &&
        ts.isVariableDeclaration(name.parent) &&
        name.parent.name === name
      ) {
        storeValueKind(name.text, scopedKind);
      }
      if (kind === 'factory' && !isParamBinding) {
        factories.add(name.text);
      }
      if (kind === 'requirer' && !isParamBinding) {
        requirers.add(name.text);
      }
      if (isMutatingMethodReference(valueExpr)) {
        mutatorAliases.add(name.text);
      }
      bindIndirectAliases(name.text, valueExpr);
      const shape = shapeOverride ?? knownArrayShape(valueExpr);
      if (shape) {
        storeArrayShape(name.text, shape);
        scopedArrayShapes.set(name, shape);
      } else if (arrayShapes.has(name.text)) {
        storeArrayShape(name.text, opaqueArrayShape());
      }
      const declaredHere =
        (name.parent && ts.isVariableDeclaration(name.parent) && name.parent.name === name) ||
        (name.parent && ts.isParameter(name.parent) && name.parent.name === name) ||
        Boolean(name.parent && ts.isBindingElement(name.parent));
      if (!declaredHere) {
        const bound = enclosingBindingName(name);
        if (bound && bound !== name) {
          if (scopedKind) {
            scopedBindingKinds.set(bound, scopedKind);
          }
          if (shape) {
            scopedArrayShapes.set(bound, shape);
          }
        }
      }
      const unwrappedValue = valueExpr ? unwrapExpr(valueExpr) : undefined;
      if (unwrappedValue) {
        valueExprs.set(name.text, unwrappedValue);
      }
      if (unwrappedValue && isFunctionLikeNode(unwrappedValue)) {
        registerReturnFacts(name.text, unwrappedValue);
      }
      registerCallableFacts(name.text, unwrappedValue);
      const sourceCallableKey = callableKeyOverride ?? callableReferenceKey(unwrappedValue);
      if (sourceCallableKey !== null && sourceCallableKey !== name.text) {
        copyReturnFacts(name.text, sourceCallableKey);
      }
      if (unwrappedValue && ts.isNewExpression(unwrappedValue)) {
        const classKey = referenceKey(unwrappedValue.expression);
        if (classKey !== null) {
          classInstances.set(name.text, classKey);
        }
      } else {
        const sourceKey = referenceKey(unwrappedValue);
        const instanceClass = sourceKey === null ? undefined : classInstances.get(sourceKey);
        if (instanceClass) {
          classInstances.set(name.text, instanceClass);
        }
      }
      if (unwrappedValue && ts.isObjectLiteralExpression(unwrappedValue)) {
        registerObjectArrayShapes(name.text, unwrappedValue);
        registerObjectMethodReturns(name.text, unwrappedValue);
      } else if (unwrappedValue && isObjectAssignCall(unwrappedValue)) {
        const assignArgs = objectAssignArguments(unwrappedValue);
        for (const arg of assignArgs === null ? [] : (assignArgs ?? [])) {
          const sources = ts.isSpreadElement(arg)
            ? (expandSpread(arg.expression)?.items ?? [arg.expression])
            : [arg];
          for (const source of sources) {
            const sourceBase = referenceKey(source);
            if (sourceBase !== null) {
              copyObjectArrayShapes(name.text, sourceBase);
            }
            registerObjectArrayShapes(name.text, source);
            registerObjectMethodReturns(name.text, source);
          }
        }
      } else {
        const sourceBase = referenceKey(unwrappedValue);
        if (sourceBase !== null && shape === undefined) {
          copyObjectArrayShapes(name.text, sourceBase);
        }
      }
      return;
    }
    if (ts.isObjectBindingPattern(name)) {
      for (const element of name.elements) {
        if (!ts.isBindingElement(element)) {
          continue;
        }
        const key = bindingElementKey(element);
        let kind = inheritedKind;
        if (key === 'createRequire') {
          kind = 'factory';
        }
        if (key === 'require') {
          kind = 'requirer';
        }
        if (ts.isIdentifier(element.name) && MUTATING_ARRAY_METHODS.has(key)) {
          mutatorAliases.add(element.name.text);
        }
        if (ts.isIdentifier(element.name) && ARRAY_QUERY_METHODS.has(key)) {
          arrayMethodAliases.set(element.name.text, { method: key, object: valueExpr });
        }
        if (ts.isIdentifier(element.name) && key === 'assign' && isObjectIdentifier(valueExpr, 'Object')) {
          objectAssignAliases.add(element.name.text);
        }
        if (ts.isIdentifier(element.name) && key === 'from' && isObjectIdentifier(valueExpr, 'Array')) {
          arrayFromAliases.add(element.name.text);
        }
        if (ts.isIdentifier(element.name) && key === 'of' && isObjectIdentifier(valueExpr, 'Array')) {
          arrayOfAliases.add(element.name.text);
        }
        if (ts.isIdentifier(element.name) && key === 'create' && isObjectIdentifier(valueExpr, 'Object')) {
          objectCreateAliases.add(element.name.text);
        }
        if (ts.isIdentifier(element.name) && key === 'setPrototypeOf' && isObjectIdentifier(valueExpr, 'Object')) {
          objectSetPrototypeOfAliases.add(element.name.text);
        }
        if (
          ts.isIdentifier(element.name) &&
          key === 'defineProperty' &&
          (isObjectIdentifier(valueExpr, 'Object') || isObjectIdentifier(valueExpr, 'Reflect'))
        ) {
          objectDefinePropertyAliases.add(element.name.text);
        }
        if (ts.isIdentifier(element.name) && key === 'defineProperties' && isObjectIdentifier(valueExpr, 'Object')) {
          objectDefinePropertiesAliases.add(element.name.text);
        }
        if (ts.isIdentifier(element.name) && key === 'construct' && isObjectIdentifier(valueExpr, 'Reflect')) {
          reflectConstructAliases.add(element.name.text);
        }
        if (ts.isIdentifier(element.name) && key === 'apply' && isObjectIdentifier(valueExpr, 'Reflect')) {
          reflectApplyAliases.add(element.name.text);
        }
        if (ts.isIdentifier(element.name) && (key === 'call' || key === 'apply')) {
          callApplyAliases.add(element.name.text);
        }
        const source = resolveObjectProperty(valueExpr, key);
        bindPattern(
          element.name,
          source?.kind ?? kind,
          source?.value ?? element.initializer,
          source?.shape,
          source?.callableKey,
        );
      }
      return;
    }
    if (ts.isArrayBindingPattern(name)) {
      const shape = shapeOverride ?? shapeFromValue(valueExpr);
      name.elements.forEach((element, i) => {
        if (ts.isOmittedExpression(element) || !ts.isBindingElement(element)) {
          return;
        }
        if (element.dotDotDotToken) {
          let kind = inheritedKind;
          if (!shape.opaque) {
            for (const itemKind of shape.kinds.slice(i)) {
              if (itemKind) {
                kind = itemKind;
              }
            }
          }
          bindPattern(element.name, kind, element.initializer);
          return;
        }
        const itemKind = !shape.opaque && i < shape.kinds.length ? shape.kinds[i] : null;
        const itemValue = shape.values?.[i];
        bindPattern(element.name, itemKind ?? inheritedKind, itemValue ?? element.initializer);
      });
    }
  };

  const bindAssignmentTarget = (
    target,
    inheritedKind,
    valueExpr,
    shapeOverride,
    callableKeyOverride,
  ) => {
    target = unwrapExpr(target);
    valueExpr = valueExpr ? unwrapExpr(valueExpr) : undefined;
    if (
      ts.isIdentifier(target) ||
      ts.isObjectBindingPattern(target) ||
      ts.isArrayBindingPattern(target)
    ) {
      bindPattern(target, inheritedKind, valueExpr, shapeOverride, callableKeyOverride);
      return;
    }
    if (ts.isArrayLiteralExpression(target)) {
      const shape = shapeFromValue(valueExpr);
      target.elements.forEach((element, i) => {
        if (ts.isOmittedExpression(element) || ts.isSpreadElement(element)) {
          return;
        }
        const itemKind = !shape.opaque && i < shape.kinds.length ? shape.kinds[i] : null;
        bindAssignmentTarget(element, itemKind ?? inheritedKind, undefined);
      });
      return;
    }
    if (ts.isObjectLiteralExpression(target)) {
      for (const prop of target.properties) {
        if (ts.isShorthandPropertyAssignment(prop)) {
          let kind = inheritedKind;
          if (prop.name.text === 'createRequire') {
            kind = 'factory';
          }
          if (prop.name.text === 'require') {
            kind = 'requirer';
          }
          const source = resolveObjectProperty(valueExpr, prop.name.text);
          bindAssignmentTarget(
            prop.name,
            source?.kind ?? kind,
            source?.value,
            source?.shape,
            source?.callableKey,
          );
          continue;
        }
        if (ts.isPropertyAssignment(prop)) {
          const key = propertyNameText(prop.name);
          let kind = inheritedKind;
          if (key === 'createRequire') {
            kind = 'factory';
          }
          if (key === 'require') {
            kind = 'requirer';
          }
          const source = resolveObjectProperty(valueExpr, key);
          bindAssignmentTarget(
            prop.initializer,
            source?.kind ?? kind,
            source?.value,
            source?.shape,
            source?.callableKey,
          );
        }
      }
    }
  };

  const markArrayOpaque = (expr) => {
    expr = unwrapExpr(expr);
    const key = referenceKey(expr);
    if (key === null) {
      return;
    }
    const shape = arrayShapes.get(key);
    if (!shape) {
      arrayShapes.set(key, opaqueArrayShape());
      return;
    }
    shape.opaque = true;
  };

  const calleeProperty = (expr) => {
    expr = unwrapExpr(expr);
    if (ts.isPropertyAccessExpression(expr) && ts.isIdentifier(expr.name)) {
      return { object: expr.expression, name: expr.name.text };
    }
    if (ts.isElementAccessExpression(expr)) {
      const arg = unwrapExpr(expr.argumentExpression);
      if (arg && ts.isStringLiteralLike(arg)) {
        return { object: expr.expression, name: arg.text };
      }
      return { object: expr.expression, name: null };
    }
    return null;
  };

  const borrowedArrayMutationTarget = (node) => {
    if (!ts.isCallExpression(node)) {
      return null;
    }
    const call = calleeProperty(node.expression);
    if (!call || (call.name !== 'call' && call.name !== 'apply')) {
      return null;
    }
    const method = calleeProperty(call.object);
    if (
      (!method || !MUTATING_ARRAY_METHODS.has(method.name)) &&
      !isMutatingMethodReference(call.object)
    ) {
      return null;
    }
    const firstArgument = node.arguments[0];
    if (!firstArgument) {
      return null;
    }
    if (!ts.isSpreadElement(firstArgument)) {
      return firstArgument;
    }
    const spread = unwrapExpr(firstArgument.expression);
    if (!spread || !ts.isArrayLiteralExpression(spread)) {
      return UNRESOLVABLE_TARGET;
    }
    const first = spread.elements[0];
    return first && !ts.isOmittedExpression(first) && !ts.isSpreadElement(first) ? first : UNRESOLVABLE_TARGET;
  };

  const invalidateArrayMutation = (node) => {
    if (ts.isCallExpression(node)) {
      const borrowedTarget = borrowedArrayMutationTarget(node);
      if (borrowedTarget === UNRESOLVABLE_TARGET) {
        for (const shape of arrayShapes.values()) {
          shape.opaque = true;
        }
        return;
      }
      if (borrowedTarget) {
        markArrayOpaque(borrowedTarget);
        return;
      }
      const access = calleeProperty(node.expression);
      if (access && (access.name === null || MUTATING_ARRAY_METHODS.has(access.name))) {
        markArrayOpaque(access.object);
      }
      return;
    }
    if (ts.isBinaryExpression(node) && ts.isAssignmentOperator(node.operatorToken.kind)) {
      const left = unwrapExpr(node.left);
      if (ts.isElementAccessExpression(left)) {
        const argument = unwrapExpr(left.argumentExpression);
        if (ts.isStringLiteralLike(argument)) {
          markArrayOpaque(left);
        } else {
          markArrayOpaque(left.expression);
        }
      } else if (ts.isPropertyAccessExpression(left)) {
        if (left.name.text === 'length') {
          markArrayOpaque(left.expression);
        } else {
          markArrayOpaque(left);
        }
      }
    }
  };

  const shapeHasPropagatableFacts = (shape) =>
    Boolean(
      shape &&
        (shape.kinds.some((kind) => kind === 'factory' || kind === 'requirer') ||
          shape.values?.some(Boolean)),
    );

  const argumentCarriesTrackedFacts = (arg) => {
    const kind = classifyExpr(arg);
    if (kind === 'factory' || kind === 'requirer') {
      return true;
    }
    const returned = callableReturnKind(arg);
    if (returned === 'factory' || returned === 'requirer') {
      return true;
    }
    if (shapeHasPropagatableFacts(knownArrayShape(arg))) {
      return true;
    }
    const unwrapped = unwrapExpr(arg);
    if (!unwrapped) {
      return false;
    }
    if (
      ts.isArrayLiteralExpression(unwrapped) ||
      ts.isNewExpression(unwrapped) ||
      isObjectAssignCall(unwrapped)
    ) {
      return true;
    }
    if (ts.isObjectLiteralExpression(unwrapped)) {
      let hasConcreteProperty = false;
      let hasNonOpaqueSpread = false;
      for (const property of unwrapped.properties) {
        if (ts.isSpreadAssignment(property)) {
          if (!isOpaqueObjectSource(property.expression)) {
            hasNonOpaqueSpread = true;
          }
          continue;
        }
        hasConcreteProperty = true;
      }
      if (!hasConcreteProperty && !hasNonOpaqueSpread) {
        return false;
      }
      return true;
    }
    const key = referenceKey(unwrapped);
    if (key === null) {
      return false;
    }
    if (hasReturnFacts(key) || valueKinds.has(key) || classInstances.has(key)) {
      return true;
    }
    if (shapeHasPropagatableFacts(arrayShapes.get(key))) {
      return true;
    }
    const prefix = `${key}.`;
    for (const factKey of [
      ...arrayShapes.keys(),
      ...valueKinds.keys(),
      ...functionReturns.keys(),
      ...functionReturnExprs.keys(),
      ...valueExprs.keys(),
      ...classInstances.keys(),
    ]) {
      if (factKey.startsWith(prefix)) {
        return true;
      }
    }
    return false;
  };

  const argumentLooksLoaderish = (arg) => {
    const unwrapped = unwrapExpr(arg);
    if (!unwrapped) {
      return false;
    }
    const member = staticMember(unwrapped);
    return Boolean(member && LOADERISH_PROPERTIES.has(member.name));
  };

  const isSafeNonLoaderArg = (arg) => {
    const unwrapped = unwrapExpr(arg);
    if (!unwrapped) {
      return false;
    }
    if (
      ts.isStringLiteralLike(unwrapped) ||
      ts.isNumericLiteral(unwrapped) ||
      ts.isRegularExpressionLiteral(unwrapped) ||
      unwrapped.kind === ts.SyntaxKind.TrueKeyword ||
      unwrapped.kind === ts.SyntaxKind.FalseKeyword ||
      unwrapped.kind === ts.SyntaxKind.NullKeyword ||
      unwrapped.kind === ts.SyntaxKind.UndefinedKeyword
    ) {
      return true;
    }
    if (ts.isIdentifier(unwrapped) && unwrapped.text === 'undefined') {
      return true;
    }
    if (isFunctionLikeNode(unwrapped)) {
      return classifyExpr(unwrapped) === null && callableReturnKind(unwrapped) === null;
    }
    return false;
  };

  const isPassThroughCallbackArg = (arg) => {
    const unwrapped = unwrapExpr(arg);
    if (!unwrapped || !ts.isIdentifier(unwrapped)) {
      return false;
    }
    const bound = enclosingBindingName(unwrapped);
    return Boolean(bound && parameterFromName(bound));
  };

  const resolveAliasedValue = (expr, seen = new Set()) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped || seen.has(unwrapped)) {
      return unwrapped;
    }
    if (ts.isIdentifier(unwrapped)) {
      const stored = valueExprs.get(unwrapped.text);
      if (stored && stored !== unwrapped) {
        const nextSeen = new Set(seen);
        nextSeen.add(unwrapped);
        return resolveAliasedValue(stored, nextSeen);
      }
    }
    return unwrapped;
  };

  const resolvedOpaqueSource = (expr) => isOpaqueObjectSource(resolveAliasedValue(expr) ?? expr);

  const expandBranchExprs = (expr, seen = new Set()) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped || seen.has(unwrapped)) {
      return [];
    }
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    if (ts.isConditionalExpression(unwrapped)) {
      return [
        ...expandBranchExprs(unwrapped.whenTrue, nextSeen),
        ...expandBranchExprs(unwrapped.whenFalse, nextSeen),
      ];
    }
    if (isLogicalBinary(unwrapped)) {
      return [
        ...expandBranchExprs(unwrapped.left, nextSeen),
        ...expandBranchExprs(unwrapped.right, nextSeen),
      ];
    }
    return [unwrapped];
  };

  const objectLiteralPropertyValue = (valueExpr, key) => {
    const unwrapped = resolveAliasedValue(valueExpr);
    if (!unwrapped || !ts.isObjectLiteralExpression(unwrapped)) {
      return undefined;
    }
    let found;
    let foundIndex = -1;
    let lastOpaqueSpreadIndex = -1;
    for (let i = 0; i < unwrapped.properties.length; i++) {
      const property = unwrapped.properties[i];
      if (ts.isSpreadAssignment(property)) {
        const nested = objectLiteralPropertyValue(property.expression, key);
        if (nested && !nested?.opaque) {
          found = nested;
          foundIndex = i;
        } else if (isOpaqueObjectSource(property.expression)) {
          lastOpaqueSpreadIndex = i;
        }
        continue;
      }
      let propertyKey = null;
      let propertyValue;
      if (ts.isShorthandPropertyAssignment(property)) {
        propertyKey = property.name.text;
        propertyValue = property.name;
      } else if (ts.isPropertyAssignment(property)) {
        propertyKey = propertyNameText(property.name);
        propertyValue = property.initializer;
      } else if (ts.isMethodDeclaration(property) || ts.isGetAccessorDeclaration(property)) {
        propertyKey = propertyNameText(property.name);
        propertyValue = property;
      }
      if (propertyKey === key) {
        found = propertyValue;
        foundIndex = i;
      }
    }
    if (
      LOADERISH_PROPERTIES.has(key) &&
      lastOpaqueSpreadIndex >= 0 &&
      (foundIndex < 0 || lastOpaqueSpreadIndex > foundIndex)
    ) {
      return { opaque: true };
    }
    return found;
  };

  const interpretDescriptorFromLiteral = (literal) => {
    const getter = objectLiteralPropertyValue(literal, 'get');
    if (getter && !getter?.opaque) {
      const fn = unwrapExpr(getter);
      const kind =
        classifyExpr(getter) ??
        (fn && isFunctionLikeNode(fn) ? functionReturnKind(fn) : null);
      if (kind === 'factory' || kind === 'requirer') {
        return {
          value: getter,
          kind: kind === 'factory' ? 'requirer' : kind,
          shape: knownArrayShape(getter),
          callableKey: null,
        };
      }
    }
    const value = objectLiteralPropertyValue(literal, 'value');
    if (value && !value?.opaque) {
      const fn = unwrapExpr(value);
      const kind =
        classifyExpr(value) ??
        (fn && isFunctionLikeNode(fn) ? functionReturnKind(fn) : null);
      if (kind === 'factory' || kind === 'requirer') {
        return {
          value,
          kind: kind === 'factory' ? 'requirer' : kind,
          shape: knownArrayShape(value),
          callableKey: null,
        };
      }
    }
    if (getter?.opaque || value?.opaque) {
      return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
    }
    return undefined;
  };

  const descriptorLiteralIsDangerous = (literal) => {
    if (!literal || !ts.isObjectLiteralExpression(literal)) {
      return false;
    }
    const self = interpretDescriptorFromLiteral(literal);
    if (
      self?.returns === 'requirer' ||
      self?.kind === 'factory' ||
      self?.kind === 'requirer'
    ) {
      return true;
    }
    for (const property of literal.properties) {
      if (ts.isSpreadAssignment(property)) {
        if (isOpaqueObjectSource(property.expression)) {
          return true;
        }
        const spreadInterpreted = interpretDescriptor(property.expression);
        if (
          spreadInterpreted?.returns === 'requirer' ||
          spreadInterpreted?.kind === 'factory' ||
          spreadInterpreted?.kind === 'requirer'
        ) {
          return true;
        }
        continue;
      }
      if (
        ts.isMethodDeclaration(property) ||
        ts.isGetAccessorDeclaration(property) ||
        ts.isSetAccessorDeclaration(property)
      ) {
        continue;
      }
      let propertyValue;
      if (ts.isShorthandPropertyAssignment(property)) {
        const unwrapped = resolveAliasedValue(property.name);
        if (!unwrapped || !ts.isObjectLiteralExpression(unwrapped)) {
          continue;
        }
        propertyValue = property.name;
      } else if (ts.isPropertyAssignment(property)) {
        const unwrapped = unwrapExpr(property.initializer);
        if (!unwrapped || !ts.isObjectLiteralExpression(unwrapped)) {
          continue;
        }
        propertyValue = property.initializer;
      } else {
        continue;
      }
      const interpreted = interpretDescriptor(propertyValue);
      if (
        interpreted?.returns === 'requirer' ||
        interpreted?.kind === 'factory' ||
        interpreted?.kind === 'requirer'
      ) {
        return true;
      }
    }
    return false;
  };

  const pickDescriptorLiteral = (literals) => {
    let fallback = null;
    for (const literal of literals) {
      if (descriptorLiteralIsDangerous(literal)) {
        return literal;
      }
      if (!fallback) {
        fallback = literal;
      }
    }
    return fallback;
  };

  const collectDescriptorLiterals = (descriptorExpr, seen = new Set()) => {
    const unwrapped = resolveAliasedValue(descriptorExpr);
    if (!unwrapped) {
      return [];
    }
    if (seen.has(unwrapped)) {
      return [];
    }
    seen.add(unwrapped);
    if (ts.isObjectLiteralExpression(unwrapped)) {
      return [unwrapped];
    }
    const literals = [];
    const callableExpr = ts.isCallExpression(unwrapped) ? unwrapped.expression : unwrapped;
    for (const returned of returnExprsForCallable(callableExpr)) {
      for (const branch of expandBranchExprs(returned, seen)) {
        literals.push(...collectDescriptorLiterals(branch, seen));
      }
    }
    if (ts.isIdentifier(unwrapped)) {
      const stored = valueExprs.get(unwrapped.text);
      if (stored && stored !== unwrapped) {
        literals.push(...collectDescriptorLiterals(stored, seen));
      }
    }
    return literals;
  };

  const resolveDescriptorLiteral = (descriptorExpr, seen = new Set()) => {
    return pickDescriptorLiteral(collectDescriptorLiterals(descriptorExpr, seen));
  };

  const interpretDescriptor = (descriptorExpr) => {
    const literal = resolveDescriptorLiteral(descriptorExpr);
    if (!literal) {
      const aliased = resolveAliasedValue(descriptorExpr);
      if (isOpaqueObjectSource(aliased ?? descriptorExpr)) {
        return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
      }
      return undefined;
    }
    const fromLiteral = interpretDescriptorFromLiteral(literal);
    if (fromLiteral) {
      return fromLiteral;
    }
    if (isOpaqueObjectSource(descriptorExpr)) {
      return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
    }
    return undefined;
  };

  const markOpaqueDefinedProperty = (targetKey, propName) => {
    if (!targetKey || !propName) {
      return;
    }
    const factKey = `${targetKey}.${propName}`;
    storeValueKind(factKey, 'requirer');
  };

  const markOpaqueDefinedProperties = (targetKey) => {
    if (!targetKey) {
      return;
    }
    for (const prop of LOADERISH_PROPERTIES) {
      markOpaqueDefinedProperty(targetKey, prop);
    }
  };

  const resolveDescriptorMapProperty = (descriptorsExpr, key) => {
    const literal = resolveDescriptorLiteral(descriptorsExpr);
    if (!literal) {
      if (resolvedOpaqueSource(descriptorsExpr) && LOADERISH_PROPERTIES.has(key)) {
        return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
      }
      return undefined;
    }
    let descriptor;
    let descriptorIndex = -1;
    let lastOpaqueSpreadIndex = -1;
    for (let i = 0; i < literal.properties.length; i++) {
      const property = literal.properties[i];
      if (ts.isSpreadAssignment(property)) {
        const spreadDescriptor = resolveDescriptorMapProperty(property.expression, key);
        if (spreadDescriptor) {
          descriptor = spreadDescriptor;
          descriptorIndex = i;
        } else if (resolvedOpaqueSource(property.expression)) {
          lastOpaqueSpreadIndex = i;
        }
        continue;
      }
      let propertyKey = null;
      let propertyValue;
      if (ts.isShorthandPropertyAssignment(property)) {
        propertyKey = property.name.text;
        propertyValue = property.name;
      } else if (ts.isPropertyAssignment(property)) {
        propertyKey = propertyNameText(property.name);
        propertyValue = property.initializer;
      } else if (ts.isMethodDeclaration(property) || ts.isGetAccessorDeclaration(property)) {
        propertyKey = propertyNameText(property.name);
        propertyValue = property;
      }
      if (propertyKey === key) {
        descriptor = propertyValue;
        descriptorIndex = i;
      }
    }
    if (
      !descriptor &&
      lastOpaqueSpreadIndex >= 0 &&
      LOADERISH_PROPERTIES.has(key) &&
      (descriptorIndex < 0 || lastOpaqueSpreadIndex > descriptorIndex)
    ) {
      return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
    }
    if (!descriptor) {
      return undefined;
    }
    return interpretDescriptor(descriptor);
  };

  const applyDefinedDescriptor = (targetKey, propName, descriptorExpr) => {
    if (!targetKey || !propName) {
      return;
    }
    const factKey = `${targetKey}.${propName}`;
    const aliasedDescriptor = resolveAliasedValue(descriptorExpr);
    if (aliasedDescriptor && ts.isCallExpression(aliasedDescriptor)) {
      const calleeKey = callableReferenceKey(unwrapExpr(aliasedDescriptor.expression));
      const returnExprs =
        calleeKey === null ? [] : functionReturnExprs.get(inheritedFactKey(calleeKey)) ?? [];
      const expandedReturns = returnExprs.flatMap((returned) => expandBranchExprs(returned));
      if (expandedReturns.length > 1) {
        for (const returned of expandedReturns) {
          const literal = resolveDescriptorLiteral(returned);
          if (!literal || !descriptorLiteralIsDangerous(literal)) {
            continue;
          }
          storeValueKind(factKey, 'requirer');
          const getter = objectLiteralPropertyValue(literal, 'get');
          if (getter && !getter?.opaque) {
            const fn = unwrapExpr(getter);
            if (fn && isFunctionLikeNode(fn)) {
              registerReturnFacts(factKey, fn);
            }
            registerCallableFacts(factKey, getter);
            if (fn) {
              valueExprs.set(factKey, fn);
            }
          }
          return;
        }
      }
    }
    const interpreted = interpretDescriptor(descriptorExpr);
    if (interpreted?.returns === 'requirer') {
      markOpaqueDefinedProperty(targetKey, propName);
      return;
    }
    if (interpreted?.kind === 'factory' || interpreted?.kind === 'requirer') {
      const kind = interpreted.kind === 'factory' ? 'requirer' : interpreted.kind;
      storeValueKind(factKey, kind);
      const assigned = interpreted.value ? unwrapExpr(interpreted.value) : undefined;
      if (assigned) {
        valueExprs.set(factKey, assigned);
      }
      if (interpreted.value) {
        registerCallableFacts(factKey, interpreted.value);
        registerObjectArrayShapes(factKey, interpreted.value);
        registerObjectMethodReturns(factKey, interpreted.value);
      }
      return;
    }
    const literal = resolveDescriptorLiteral(descriptorExpr);
    if (!literal) {
      const aliased = resolveAliasedValue(descriptorExpr);
      if (isOpaqueObjectSource(aliased ?? descriptorExpr)) {
        markOpaqueDefinedProperty(targetKey, propName);
      }
      return;
    }
    const getter = objectLiteralPropertyValue(literal, 'get');
    if (getter && !getter?.opaque) {
      const fn = unwrapExpr(getter);
      if (fn && isFunctionLikeNode(fn)) {
        registerReturnFacts(factKey, fn);
      }
      registerCallableFacts(factKey, getter);
      if (fn) {
        valueExprs.set(factKey, fn);
      }
    }
    const value = objectLiteralPropertyValue(literal, 'value');
    if (value && !value?.opaque) {
      const kind = classifyExpr(value);
      if (kind === 'factory' || kind === 'requirer') {
        storeValueKind(factKey, kind);
      }
      const assigned = unwrapExpr(value);
      if (assigned) {
        valueExprs.set(factKey, assigned);
      }
      registerCallableFacts(factKey, value);
      registerObjectArrayShapes(factKey, value);
      registerObjectMethodReturns(factKey, value);
    }
    if ((getter?.opaque || value?.opaque) && !valueKinds.has(factKey)) {
      markOpaqueDefinedProperty(targetKey, propName);
    }
  };

  const registerDescriptorMapPropertiesFromLiteral = (targetKey, props) => {
    let lastOpaqueSpreadIndex = -1;
    const explicitProperties = [];
    for (let i = 0; i < props.properties.length; i++) {
      const property = props.properties[i];
      if (ts.isSpreadAssignment(property)) {
        if (resolvedOpaqueSource(property.expression)) {
          lastOpaqueSpreadIndex = i;
        } else {
          registerDescriptorMapProperties(targetKey, property.expression);
        }
        continue;
      }
      let propertyKey = null;
      let propertyValue;
      if (ts.isShorthandPropertyAssignment(property)) {
        propertyKey = property.name.text;
        propertyValue = property.name;
      } else if (ts.isPropertyAssignment(property)) {
        propertyKey = propertyNameText(property.name);
        propertyValue = property.initializer;
      } else if (ts.isMethodDeclaration(property) || ts.isGetAccessorDeclaration(property)) {
        propertyKey = propertyNameText(property.name);
        propertyValue = property;
      }
      if (propertyKey) {
        explicitProperties.push({ index: i, key: propertyKey, value: propertyValue });
      }
    }
    for (const { key, value } of explicitProperties) {
      applyDefinedDescriptor(targetKey, key, value);
    }
    if (lastOpaqueSpreadIndex >= 0) {
      for (const prop of LOADERISH_PROPERTIES) {
        const explicit = explicitProperties.find((entry) => entry.key === prop);
        if (!explicit || lastOpaqueSpreadIndex > explicit.index) {
          markOpaqueDefinedProperty(targetKey, prop);
        }
      }
    }
  };

  const registerDescriptorMapProperties = (targetKey, propsExpr) => {
    const literal = resolveDescriptorLiteral(propsExpr);
    if (literal) {
      registerDescriptorMapPropertiesFromLiteral(targetKey, literal);
      return;
    }
    const literals = collectDescriptorLiterals(propsExpr);
    if (literals.length > 0) {
      for (const collected of literals) {
        registerDescriptorMapPropertiesFromLiteral(targetKey, collected);
      }
      return;
    }
    const props = resolveAliasedValue(propsExpr);
    if (!props || !ts.isObjectLiteralExpression(props)) {
      if (resolvedOpaqueSource(propsExpr)) {
        markOpaqueDefinedProperties(targetKey);
      }
      return;
    }
    registerDescriptorMapPropertiesFromLiteral(targetKey, props);
  };

  const registerDefinePropertyCall = (node) => {
    if (!ts.isCallExpression(node)) {
      return;
    }
    const inv = invocationOf(node);
    if (!inv) {
      return;
    }
    if (isObjectDefinePropertyCallee(inv.callee)) {
      if (inv.unresolvable || inv.args.length < 3) {
        return;
      }
      const targetKey = referenceKey(inv.args[0]);
      const propName = staticStringValue(inv.args[1]);
      applyDefinedDescriptor(targetKey, propName, inv.args[2]);
      return;
    }
    if (!isObjectDefinePropertiesCallee(inv.callee) || inv.unresolvable || inv.args.length < 2) {
      return;
    }
    const targetKey = referenceKey(inv.args[0]);
    if (targetKey === null) {
      return;
    }
    registerDescriptorMapProperties(targetKey, inv.args[1]);
  };

  const registerSetPrototypeOfCall = (node) => {
    if (!ts.isCallExpression(node)) {
      return;
    }
    const inv = invocationOf(node);
    if (!inv || !isObjectSetPrototypeOfCallee(inv.callee) || inv.unresolvable || inv.args.length < 2) {
      return;
    }
    const targetKey = referenceKey(inv.args[0]);
    if (targetKey === null) {
      return;
    }
    prototypeExprs.set(targetKey, inv.args[1]);
  };

  const patternUsesCalleeParam = (pattern) => {
    if (ts.isIdentifier(pattern)) {
      return paramsUsedAsCallees.has(pattern);
    }
    if (ts.isObjectBindingPattern(pattern) || ts.isArrayBindingPattern(pattern)) {
      for (const element of pattern.elements) {
        if (ts.isBindingElement(element) && patternUsesCalleeParam(element.name)) {
          return true;
        }
      }
    }
    return false;
  };

  const isParamCalleeUsed = (paramPattern) => patternUsesCalleeParam(paramPattern);

  const callBindingFor = (node) => {
    if (!ts.isCallExpression(node)) {
      return null;
    }
    const bound = unwrapBindCall(node.expression);
    const callee = unwrapExpr(bound.target);
    const rawArgs = [...bound.boundArgs, ...node.arguments];
    const applied = callApplyBindingFrom(callee, rawArgs);
    if (applied) {
      return {
        key: applied.targetExpr ? callableReferenceKey(applied.targetExpr) : null,
        args: applied.fnArgs,
        unresolvable: applied.unresolvable,
      };
    }
    const flat = flattenCallArguments(rawArgs);
    return {
      key: callableReferenceKey(callee),
      args: flat.items,
      unresolvable: flat.unresolvable,
    };
  };

  const bindPatternDefault = (pattern, initializer) => {
    const initKind = classifyExpr(initializer);
    if (initKind === 'factory' || initKind === 'requirer') {
      bindPattern(pattern, initKind, initializer);
      return;
    }
    const unwrapped = unwrapExpr(initializer);
    if (ts.isCallExpression(unwrapped) && resolvedOpaqueSource(unwrapped)) {
      bindPattern(pattern, 'requirer', initializer);
      return;
    }
    if (ts.isObjectBindingPattern(pattern) || ts.isArrayBindingPattern(pattern)) {
      bindDestructuredArg(pattern, initializer, initKind);
      return;
    }
    if (initKind !== null) {
      bindPattern(pattern, initKind, initializer);
    }
  };

  const bindMissingBindingElementDefaults = (pattern) => {
    if (ts.isObjectBindingPattern(pattern)) {
      for (const element of pattern.elements) {
        if (!ts.isBindingElement(element)) {
          continue;
        }
        if (element.dotDotDotToken) {
          if (patternUsesCalleeParam(element.name)) {
            bindPattern(element.name, 'requirer', undefined);
          }
          continue;
        }
        if (element.initializer) {
          bindPatternDefault(element.name, element.initializer);
        } else if (patternUsesCalleeParam(element.name)) {
          bindPattern(element.name, 'requirer', undefined);
        }
      }
      return;
    }
    if (ts.isArrayBindingPattern(pattern)) {
      for (const element of pattern.elements) {
        if (!ts.isBindingElement(element) || ts.isOmittedExpression(element)) {
          continue;
        }
        if (element.dotDotDotToken) {
          if (patternUsesCalleeParam(element.name)) {
            bindPattern(element.name, 'requirer', undefined);
          }
          continue;
        }
        if (element.initializer) {
          bindPatternDefault(element.name, element.initializer);
        }
      }
    }
  };

  const resolvedBindingSource = (arg, elementKey) => {
    const source = elementKey !== null ? resolveObjectProperty(arg, elementKey) : undefined;
    if (!source?.value) {
      return source;
    }
    const value = unwrapExpr(source.value);
    if (!ts.isGetAccessorDeclaration(value) && !ts.isMethodDeclaration(value)) {
      return source;
    }
    const returns = collectReturnExprs(value);
    if (returns.length === 0) {
      return source;
    }
    for (const returned of returns) {
      const kind = classifyExpr(returned);
      if (kind === 'factory' || kind === 'requirer') {
        return {
          value: returned,
          kind,
          shape: knownArrayShape(returned),
          callableKey: null,
        };
      }
      if (resolvedOpaqueSource(returned)) {
        return {
          value: returned,
          kind: null,
          shape: undefined,
          callableKey: null,
          returns: 'requirer',
        };
      }
    }
    if (returns.length === 1) {
      const returned = returns[0];
      return {
        value: returned,
        kind: classifyExpr(returned),
        shape: knownArrayShape(returned),
        callableKey: null,
      };
    }
    return source;
  };

  const bindDestructuredArg = (
    pattern,
    arg,
    inheritedKind,
    inheritedShape,
    inheritedCallableKey,
    inheritedReturns,
  ) => {
    const inheritedResolved = {
      kind: inheritedKind,
      shape: inheritedShape,
      callableKey: inheritedCallableKey,
      value: arg,
      returns: inheritedReturns,
    };
    const effectiveKind = dangerousPropertyKind(inheritedResolved) ?? inheritedKind;
    if (ts.isIdentifier(pattern)) {
      const calleeUsed = paramsUsedAsCallees.has(pattern);
      if (!argumentCarriesTrackedFacts(arg) && calleeUsed) {
        if (
          effectiveKind === 'factory' ||
          effectiveKind === 'requirer' ||
          inheritedReturns === 'requirer' ||
          argumentLooksLoaderish(arg)
        ) {
          bindPattern(pattern, 'requirer', undefined);
          return;
        }
        if (!isSafeNonLoaderArg(arg) && !isPassThroughCallbackArg(arg)) {
          bindPattern(pattern, 'requirer', undefined);
          return;
        }
      }
      bindPattern(pattern, effectiveKind, arg, inheritedShape, inheritedCallableKey);
      return;
    }
    if (ts.isObjectBindingPattern(pattern)) {
      for (const element of pattern.elements) {
        if (!ts.isBindingElement(element)) {
          continue;
        }
        if (element.dotDotDotToken) {
          const restOpaque =
            resolvedOpaqueSource(arg) ||
            classifyExpr(arg) === null ||
            dangerousPropertyKind({ kind: inheritedKind, returns: inheritedReturns }) !== null;
          if (restOpaque && patternUsesCalleeParam(element.name)) {
            bindPattern(element.name, 'requirer', undefined);
          }
          continue;
        }
        const elementKey = bindingElementKey(element);
        const source = elementKey !== null ? resolvedBindingSource(arg, elementKey) : undefined;
        if ((!source || source.value === undefined) && element.initializer) {
          bindPatternDefault(element.name, element.initializer);
          continue;
        }
        const nextKind = dangerousPropertyKind(source) ?? source?.kind ?? inheritedKind;
        bindDestructuredArg(
          element.name,
          source?.value ?? arg,
          nextKind,
          source?.shape ?? inheritedShape,
          source?.callableKey ?? inheritedCallableKey,
          source?.returns ?? inheritedReturns,
        );
      }
      return;
    }
    if (ts.isArrayBindingPattern(pattern)) {
      const shape = inheritedShape ?? shapeFromValue(arg);
      pattern.elements.forEach((element, i) => {
        if (ts.isOmittedExpression(element) || !ts.isBindingElement(element)) {
          return;
        }
        const itemKind = !shape.opaque && i < shape.kinds.length ? shape.kinds[i] : inheritedKind;
        const itemValue = shape.values?.[i];
        bindDestructuredArg(
          element.name,
          itemValue ?? arg,
          itemKind ?? inheritedKind,
          inheritedShape,
          inheritedCallableKey,
          inheritedReturns,
        );
      });
    }
  };

  const bindCallArguments = (node) => {
    if (!ts.isCallExpression(node)) {
      return;
    }
    const binding = callBindingFor(node);
    if (!binding) {
      return;
    }
    const key = binding.key;
    const params = key === null ? undefined : functionParams.get(inheritedFactKey(key));
    if (!params) {
      return;
    }
    const args = binding.args;
    const flat = { items: args, unresolvable: binding.unresolvable };
    params.forEach((paramName, i) => {
      const param = parameterFromName(paramName);
      if (
        i < args.length &&
        patternUsesCalleeParam(paramName) &&
        ts.isIdentifier(args[i])
      ) {
        const callerBinding = enclosingBindingName(args[i]);
        if (callerBinding && parameterFromName(callerBinding)) {
          markParamCallee(callerBinding);
        }
      }
      if (param?.dotDotDotToken) {
        const restArgs = i < args.length ? args.slice(i) : [];
        if (ts.isObjectBindingPattern(paramName) || ts.isArrayBindingPattern(paramName)) {
          if (flat.unresolvable && restArgs.length === 0) {
            bindPattern(paramName, 'requirer', undefined);
            return;
          }
          for (const arg of restArgs) {
            bindDestructuredArg(paramName, arg, classifyExpr(arg));
          }
          if (restArgs.length === 0) {
            bindMissingBindingElementDefaults(paramName);
          }
          return;
        }
        const shape = shapeOf(
          restArgs.some((arg) => classifyExpr(arg) === null) || flat.unresolvable,
          restArgs.map((arg) => classifyExpr(arg)),
          restArgs,
        );
        bindPattern(paramName, null, undefined, shape);
        return;
      }
      if (i >= args.length) {
        if (flat.unresolvable) {
          bindPattern(paramName, 'requirer', undefined);
          return;
        }
        if (param?.initializer) {
          bindPatternDefault(paramName, param.initializer);
        } else if (ts.isObjectBindingPattern(paramName) || ts.isArrayBindingPattern(paramName)) {
          bindMissingBindingElementDefaults(paramName);
        }
        return;
      }
      if (ts.isObjectBindingPattern(paramName) || ts.isArrayBindingPattern(paramName)) {
        bindDestructuredArg(paramName, args[i], classifyExpr(args[i]));
        return;
      }
      if (ts.isIdentifier(paramName) && !argumentCarriesTrackedFacts(args[i])) {
        if (argumentLooksLoaderish(args[i])) {
          bindPattern(paramName, 'requirer', undefined);
        } else if (isParamCalleeUsed(paramName)) {
          if (ts.isIdentifier(args[i]) && parameterFromName(enclosingBindingName(args[i]))) {
            const argKind = classifyExpr(args[i]);
            if (argKind === 'factory' || argKind === 'requirer') {
              bindPattern(paramName, argKind, args[i]);
              return;
            }
          }
          if (!isPassThroughCallbackArg(args[i]) && !isSafeNonLoaderArg(args[i])) {
            bindPattern(paramName, 'requirer', undefined);
          }
        }
        return;
      }
      bindPattern(paramName, classifyExpr(args[i]), args[i]);
    });
  };

  const bindNode = (node) => {
    invalidateArrayMutation(node);
    registerDefinePropertyCall(node);
    registerSetPrototypeOfCall(node);
    bindCallArguments(node);
    if (isFunctionLikeNode(node) && node.parameters) {
      for (const param of node.parameters) {
        if (param.initializer) {
          bindPattern(param.name, classifyExpr(param.initializer), param.initializer);
        }
      }
    }
    if (ts.isVariableDeclaration(node) && node.initializer) {
      bindPattern(node.name, classifyExpr(node.initializer), node.initializer);
    }
    if (ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.EqualsToken) {
      const left = unwrapExpr(node.left);
      const protoMember = staticMember(left);
      if (protoMember?.name === '__proto__') {
        const targetKey = referenceKey(protoMember.object);
        if (targetKey !== null) {
          prototypeExprs.set(targetKey, unwrapExpr(node.right));
        }
      }
      const leftKey = referenceKey(left);
      if (leftKey !== null && !ts.isIdentifier(left)) {
        valueExprs.set(leftKey, unwrapExpr(node.right));
        const kind = classifyExpr(node.right);
        if (kind === 'factory' || kind === 'requirer') {
          storeValueKind(leftKey, kind);
        } else {
          valueKinds.delete(leftKey);
        }
        const shape = knownArrayShape(node.right);
        if (shape) {
          storeArrayShape(leftKey, shape);
        } else if (arrayShapes.has(leftKey)) {
          markArrayOpaque(left);
        }
        registerCallableFacts(leftKey, node.right);
        const assigned = unwrapExpr(node.right);
        if (assigned && ts.isNewExpression(assigned)) {
          const classKey = referenceKey(assigned.expression);
          if (classKey !== null) classInstances.set(leftKey, classKey);
        }
      }
      bindAssignmentTarget(node.left, classifyExpr(node.right), node.right);
    }
    ts.forEachChild(node, bindNode);
    registerFunctionReturn(node);
  };

  const isOpaqueArrayBind = (node) => {
    if (ts.isVariableDeclaration(node) && node.initializer && ts.isArrayBindingPattern(node.name)) {
      return shapeFromValue(node.initializer).opaque;
    }
    if (ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.EqualsToken) {
      const left = unwrapExpr(node.left);
      if (ts.isArrayLiteralExpression(left) || ts.isArrayBindingPattern(left)) {
        return shapeFromValue(node.right).opaque;
      }
    }
    return false;
  };

  collectStringFacts(sourceFile);
  seedStableStringValues();
  seedImports(sourceFile);
  const snapshotShape = (shape) => (shape ? { opaque: shape.opaque, kinds: shape.kinds } : shape);

  let previous = '';
  const snapshot = () =>
    `${factories.size}|${requirers.size}|${JSON.stringify(
      [...arrayShapes.entries()].map(([key, shape]) => [key, snapshotShape(shape)]),
    )}|${JSON.stringify([...valueKinds.entries()])}|${JSON.stringify([...mutatorAliases])}|${JSON.stringify([
      ...stringValues.entries(),
    ])}|${JSON.stringify([...functionReturns.entries()])}|${JSON.stringify(
      [...functionReturnShapes.entries()].map(([key, shape]) => [key, snapshotShape(shape)]),
    )}|${JSON.stringify([...classInstances.entries()])}|${JSON.stringify([
      ...classParents.entries(),
    ])}|${JSON.stringify([...arrayMethodAliases.keys()])}|${JSON.stringify([
      ...objectAssignAliases,
    ])}|${JSON.stringify([...arrayFromAliases    ])}|${JSON.stringify([...arrayOfAliases])}|${JSON.stringify([
      ...arrayCtorAliases,
    ])}|${JSON.stringify([
      ...reflectApplyAliases,
    ])}|${JSON.stringify([
      ...callApplyAliases,
    ])}|${JSON.stringify([...objectCreateAliases])}|${JSON.stringify([
      ...objectSetPrototypeOfAliases,
    ])}|${JSON.stringify([...objectDefinePropertyAliases])}|${JSON.stringify([
      ...objectDefinePropertiesAliases,
    ])}|${JSON.stringify([
      ...reflectConstructAliases,
    ])}|${JSON.stringify(
      [...functionParams.entries()].map(([key, names]) => [
        key,
        names.map((name) => (ts.isIdentifier(name) ? name.text : String(name.kind))),
      ]),
    )}|${JSON.stringify([...prototypeExprs.keys()])}|${JSON.stringify([...paramsUsedAsCalleeKeys])}|${JSON.stringify([
      ...paramBindingKinds.entries(),
    ])}`;
  const paramCalleeKey = (paramNameNode) => {
    if (!paramNameNode || !ts.isIdentifier(paramNameNode)) {
      return null;
    }
    const param = parameterFromName(paramNameNode);
    if (!param?.parent || !isFunctionLikeNode(param.parent)) {
      return null;
    }
    const funcNode = param.parent;
    const funcKey = funcNode.name ? referenceKey(funcNode.name) : callableReferenceKey(funcNode);
    if (funcKey === null) {
      return null;
    }
    return `${inheritedFactKey(funcKey)}#${paramNameNode.text}`;
  };
  const markParamCallee = (paramNameNode) => {
    if (!paramNameNode) {
      return;
    }
    paramsUsedAsCallees.add(paramNameNode);
    const key = paramCalleeKey(paramNameNode);
    if (key) {
      paramsUsedAsCalleeKeys.add(key);
    }
  };
  const registerParamNames = (pattern, names) => {
    if (ts.isIdentifier(pattern)) {
      names.set(pattern.text, pattern);
      return;
    }
    if (ts.isObjectBindingPattern(pattern)) {
      for (const element of pattern.elements) {
        if (!ts.isBindingElement(element)) {
          continue;
        }
        if (ts.isIdentifier(element.name)) {
          const key = bindingElementKey(element);
          if (key !== null) {
            names.set(key, element.name);
          }
          names.set(element.name.text, element.name);
        } else {
          registerParamNames(element.name, names);
        }
      }
      return;
    }
    if (ts.isArrayBindingPattern(pattern)) {
      for (const element of pattern.elements) {
        if (ts.isBindingElement(element) && !ts.isOmittedExpression(element)) {
          registerParamNames(element.name, names);
        }
      }
    }
  };
  const collectParamsUsedAsCallees = (node) => {
    if (isFunctionLikeNode(node) && node.body && node.parameters) {
      const names = new Map();
      const localAliases = new Map();
      for (const param of node.parameters) {
        registerParamNames(param.name, names);
      }
      const resolveCalleeParam = (calleeIdent) => {
        let current = calleeIdent.text;
        const seen = new Set();
        while (!seen.has(current)) {
          seen.add(current);
          if (names.has(current)) {
            return names.get(current);
          }
          if (localAliases.has(current)) {
            const target = localAliases.get(current);
            if (ts.isIdentifier(target)) {
              current = target.text;
              continue;
            }
            return target;
          }
          break;
        }
        return null;
      };
      const visitAliases = (child) => {
        if (child !== node && isFunctionLikeNode(child)) {
          return;
        }
        if (ts.isVariableDeclaration(child) && child.initializer && ts.isIdentifier(child.name)) {
          const init = unwrapExpr(child.initializer);
          if (init && ts.isIdentifier(init)) {
            if (names.has(init.text)) {
              localAliases.set(child.name.text, names.get(init.text));
            } else if (localAliases.has(init.text)) {
              localAliases.set(child.name.text, localAliases.get(init.text));
            }
          }
        }
        if (
          ts.isBinaryExpression(child) &&
          child.operatorToken.kind === ts.SyntaxKind.EqualsToken
        ) {
          const left = unwrapExpr(child.left);
          const right = unwrapExpr(child.right);
          if (left && ts.isIdentifier(left) && right && ts.isIdentifier(right)) {
            if (names.has(right.text)) {
              localAliases.set(left.text, names.get(right.text));
            } else if (localAliases.has(right.text)) {
              localAliases.set(left.text, localAliases.get(right.text));
            }
          }
        }
        ts.forEachChild(child, visitAliases);
      };
      visitAliases(node.body);
      const visit = (child) => {
        if (child !== node && isFunctionLikeNode(child)) {
          return;
        }
        if (ts.isCallExpression(child)) {
          let callee = unwrapExpr(child.expression);
          const access = staticMember(callee);
          if (access && (access.name === 'call' || access.name === 'apply' || access.name === 'bind')) {
            callee = unwrapExpr(access.object);
          }
          if (callee && ts.isIdentifier(callee)) {
            const paramName = resolveCalleeParam(callee);
            if (paramName) {
              markParamCallee(paramName);
            }
          }
        }
        ts.forEachChild(child, visit);
      };
      visit(node.body);
    }
    ts.forEachChild(node, collectParamsUsedAsCallees);
  };
  collectParamsUsedAsCallees(sourceFile);
  while (previous !== snapshot()) {
    previous = snapshot();
    bindNode(sourceFile);
  }

  const isLoaderArgument = (expr) => {
    if (isPassThroughCallbackArg(expr)) {
      return false;
    }
    const kind = classifyExpr(expr);
    if (kind === 'factory' || kind === 'requirer') {
      return true;
    }
    const returned = callableReturnKind(expr);
    if (returned === 'factory' || returned === 'requirer') {
      return true;
    }
    const unwrapped = unwrapExpr(expr);
    if (unwrapped && ts.isArrayLiteralExpression(unwrapped)) {
      const items = expandSpread(unwrapped)?.items;
      return Boolean(items?.some((item) => isLoaderArgument(item)));
    }
    return false;
  };

  const loads = [];
  const visit = (node) => {
    loads.push(...loadsFromNode(node, classifyCallee, staticStringValue, classifyExpr, isLoaderArgument));
    if (isOpaqueArrayBind(node)) {
      loads.push({ kind: 'unsafe', reason: '非静态数组解构' });
    }
    ts.forEachChild(node, visit);
  };
  visit(sourceFile);
  return loads;
}

function loadsFromNode(
  node,
  classifyCallee,
  resolveStaticString = stringLiteralText,
  classifyExpr = () => null,
  isLoaderArgument = null,
) {
  const loads = [];
  if (ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) {
    const specifier = stringLiteralText(node.moduleSpecifier);
    if (specifier !== null) {
      loads.push({ kind: 'specifier', value: specifier });
    }
    return loads;
  }
  if (ts.isImportEqualsDeclaration(node) && ts.isExternalModuleReference(node.moduleReference)) {
    const specifier = stringLiteralText(node.moduleReference.expression);
    if (specifier !== null) {
      loads.push({ kind: 'specifier', value: specifier });
    } else {
      loads.push({ kind: 'unsafe', reason: '非字面量 import =' });
    }
    return loads;
  }
  if (ts.isImportTypeNode(node) && ts.isLiteralTypeNode(node.argument)) {
    const specifier = stringLiteralText(node.argument.literal);
    if (specifier !== null) {
      loads.push({ kind: 'specifier', value: specifier });
    }
    return loads;
  }
  if (ts.isCallExpression(node)) {
    if (node.expression.kind === ts.SyntaxKind.ImportKeyword) {
      const specifier = resolveStaticString(node.arguments[0]);
      if (specifier !== null) {
        loads.push({ kind: 'specifier', value: specifier });
      } else {
        loads.push({ kind: 'unsafe', reason: '非字面量 import()' });
      }
      return loads;
    }
    if (
      node.arguments.some((argument) => {
        const value = ts.isSpreadElement(argument) ? argument.expression : argument;
        if (isLoaderArgument) {
          return isLoaderArgument(value);
        }
        const kind = classifyExpr(value);
        return kind === 'factory' || kind === 'requirer';
      })
    ) {
      loads.push({ kind: 'unsafe', reason: '动态加载器作为参数' });
    }
    const kind = classifyCallee(node.expression);
    if (kind === 'factory') {
      loads.push({ kind: 'unsafe', reason: 'createRequire()' });
      return loads;
    }
    if (kind === 'requirer') {
      const specifier = resolveStaticString(node.arguments[0]);
      if (specifier !== null) {
        loads.push({ kind: 'specifier', value: specifier });
      } else {
        loads.push({ kind: 'unsafe', reason: '非字面量 require()' });
      }
      return loads;
    }
  }
  return loads;
}

function unwrapExpr(expr) {
  while (expr) {
    const kind = expr.kind;
    if (
      kind === ts.SyntaxKind.ParenthesizedExpression ||
      kind === ts.SyntaxKind.AsExpression ||
      kind === ts.SyntaxKind.TypeAssertionExpression ||
      kind === ts.SyntaxKind.NonNullExpression ||
      kind === ts.SyntaxKind.SatisfiesExpression
    ) {
      expr = expr.expression;
      continue;
    }
    if (
      ts.isBinaryExpression(expr) &&
      expr.operatorToken.kind === ts.SyntaxKind.CommaToken
    ) {
      expr = expr.right;
      continue;
    }
    break;
  }
  return expr;
}

function isLogicalBinary(expr) {
  return Boolean(
    expr &&
      ts.isBinaryExpression(expr) &&
      (expr.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken ||
        expr.operatorToken.kind === ts.SyntaxKind.BarBarToken ||
        expr.operatorToken.kind === ts.SyntaxKind.QuestionQuestionToken),
  );
}

function isFunctionLikeNode(node) {
  return Boolean(
    node &&
      (ts.isFunctionDeclaration(node) ||
        ts.isFunctionExpression(node) ||
        ts.isArrowFunction(node) ||
        ts.isMethodDeclaration(node) ||
        ts.isGetAccessorDeclaration(node) ||
        ts.isSetAccessorDeclaration(node) ||
        ts.isConstructorDeclaration(node)),
  );
}

function propertyNameText(name) {
  if (ts.isIdentifier(name) || ts.isStringLiteralLike(name)) {
    return name.text;
  }
  if (ts.isComputedPropertyName(name) && ts.isStringLiteralLike(unwrapExpr(name.expression))) {
    return unwrapExpr(name.expression).text;
  }
  return null;
}

function bindingElementKey(element) {
  if (element.propertyName) {
    return propertyNameText(element.propertyName);
  }
  if (ts.isIdentifier(element.name)) {
    return element.name.text;
  }
  return null;
}

function scriptKindFor(fileName) {
  if (fileName.endsWith('.tsx')) {
    return ts.ScriptKind.TSX;
  }
  if (fileName.endsWith('.jsx')) {
    return ts.ScriptKind.JSX;
  }
  if (fileName.endsWith('.mts') || fileName.endsWith('.cts') || fileName.endsWith('.ts')) {
    return ts.ScriptKind.TS;
  }
  return ts.ScriptKind.JS;
}

function stringLiteralText(node) {
  const expr = unwrapExpr(node);
  if (!expr) {
    return null;
  }
  if (ts.isStringLiteralLike(expr)) {
    return expr.text;
  }
  if (ts.isBinaryExpression(expr) && expr.operatorToken.kind === ts.SyntaxKind.PlusToken) {
    const left = stringLiteralText(expr.left);
    const right = stringLiteralText(expr.right);
    if (left !== null && right !== null) {
      return left + right;
    }
  }
  return null;
}

export function isTestkitPackageSpecifier(specifier) {
  return specifier === FORBIDDEN_PACKAGE || specifier.startsWith(`${FORBIDDEN_PACKAGE}/`);
}

function posixRelative(root, absolute) {
  return path.relative(root, absolute).split(path.sep).join('/');
}

export function isTestkitArchivePath(posix) {
  const normalized = posix.split(path.sep).join('/');
  return (
    normalized.includes('packages/testkit') ||
    normalized.includes('node_modules/@coc-helper/testkit') ||
    /(?:^|\/)@coc-helper\/testkit(?:\/|$)/.test(normalized)
  );
}

export function isTestkitFilesystemPath(absolute, workspaceRoot = defaultRoot) {
  const lexicalTestkitRoot = path.resolve(workspaceRoot, 'packages/testkit');
  const testkitRoot = existsSync(lexicalTestkitRoot)
    ? realpathSync(lexicalTestkitRoot)
    : lexicalTestkitRoot;
  const lexicalResolved = path.resolve(absolute);
  const resolved = existsSync(lexicalResolved) ? realpathSync(lexicalResolved) : lexicalResolved;
  return resolved === testkitRoot || resolved.startsWith(`${testkitRoot}${path.sep}`);
}

function resolveExistingFile(base) {
  const candidates = [base, `${base}.ts`, `${base}.js`, path.join(base, 'index.ts'), path.join(base, 'index.js')];
  for (const candidate of candidates) {
    if (existsSync(candidate) && statSync(candidate).isFile()) {
      return path.resolve(candidate);
    }
  }
  return path.resolve(base);
}

export function resolveWorkspaceSpecifier(fromRelative, specifier, workspaceRoot = defaultRoot) {
  if (isTestkitPackageSpecifier(specifier) || specifier.split(path.sep).join('/').includes('packages/testkit/')) {
    if (specifier.startsWith('.')) {
      return resolveExistingFile(path.join(workspaceRoot, path.dirname(fromRelative), specifier));
    }
    const rest = specifier.slice(FORBIDDEN_PACKAGE.length).replace(/^\//, '');
    const pkgRoot = path.join(workspaceRoot, WORKSPACE_PACKAGES[FORBIDDEN_PACKAGE]);
    return resolveExistingFile(rest ? path.join(pkgRoot, rest) : path.join(pkgRoot, 'src/index.ts'));
  }

  const names = Object.keys(WORKSPACE_PACKAGES).sort((left, right) => right.length - left.length);
  const matched = names.find((name) => specifier === name || specifier.startsWith(`${name}/`));
  if (matched) {
    const rest = specifier.slice(matched.length).replace(/^\//, '');
    const pkgRoot = path.join(workspaceRoot, WORKSPACE_PACKAGES[matched]);
    if (rest) {
      return resolveExistingFile(path.join(pkgRoot, rest));
    }
    const manifest = JSON.parse(readFileSync(path.join(pkgRoot, 'package.json'), 'utf8'));
    return resolveExistingFile(path.join(pkgRoot, manifest.main ?? 'src/index.ts'));
  }

  if (specifier.startsWith('.')) {
    return resolveExistingFile(path.join(workspaceRoot, path.dirname(fromRelative), specifier));
  }
  return null;
}

export function findForbiddenImportHits(text, fromRelative, workspaceRoot = defaultRoot) {
  const hits = [];
  for (const specifier of extractImportSpecifiers(text, fromRelative)) {
    if (isTestkitPackageSpecifier(specifier)) {
      hits.push(`${fromRelative} 不得 import ${specifier}`);
      continue;
    }
    const resolved = resolveWorkspaceSpecifier(fromRelative, specifier, workspaceRoot);
    if (resolved && isTestkitFilesystemPath(resolved, workspaceRoot)) {
      hits.push(`${fromRelative} 不得解析到 testkit（via ${specifier}）`);
    }
  }
  for (const reason of extractUnsafeDynamicLoads(text, fromRelative)) {
    hits.push(`${fromRelative} 不得使用无法静态解析的动态加载（${reason}）`);
  }
  const hasExactPackageMarker = text.includes(FORBIDDEN_PACKAGE);
  const hasPackageFragments = text.includes('@coc-helper') && /\btestkit\b/i.test(text);
  if (
    (hasExactPackageMarker || hasPackageFragments) &&
    !hits.some((hit) => hit.includes(`不得 import ${FORBIDDEN_PACKAGE}`))
  ) {
    hits.push(
      hasExactPackageMarker
        ? `${fromRelative} 不得包含 ${FORBIDDEN_PACKAGE} 字面量`
        : `${fromRelative} 不得包含 testkit 包标识或片段`,
    );
  }
  return hits;
}

function isProductionSource(relative) {
  if (!/\.(ts|js|mjs|cjs|tsx)$/.test(relative)) {
    return false;
  }
  if (relative.includes('.test.') || relative.endsWith('.test.ts')) {
    return false;
  }
  if (relative.includes('.parity.') || relative.includes('.replay.')) {
    return false;
  }
  return PRODUCTION_TREES.some((tree) => relative === tree || relative.startsWith(`${tree}/`));
}

function packageHits(workspaceRoot) {
  const hits = [];
  const productionManifests = [
    ['apps/desktop/package.json', ['dependencies', 'devDependencies']],
    ['packages/wire/package.json', ['dependencies']],
    ['packages/domain/package.json', ['dependencies']],
    ['packages/contracts/package.json', ['dependencies']],
  ];
  for (const [relative, fields] of productionManifests) {
    const json = JSON.parse(readFileSync(path.join(workspaceRoot, relative), 'utf8'));
    for (const field of fields) {
      if (json[field]?.[FORBIDDEN_PACKAGE]) {
        hits.push(`${relative} ${field} 不得依赖 ${FORBIDDEN_PACKAGE}`);
      }
    }
  }
  return hits;
}

function sourceImportHits(workspaceRoot) {
  const hits = [];
  for (const tree of PRODUCTION_TREES) {
    for (const file of walk(path.join(workspaceRoot, tree))) {
      const relative = posixRelative(workspaceRoot, file);
      if (!isProductionSource(relative)) {
        continue;
      }
      if (isTestkitFilesystemPath(file, workspaceRoot)) {
        hits.push(`生产源码通过真实路径到达 testkit：${relative}`);
        continue;
      }
      hits.push(
        ...findForbiddenImportHits(readFileSync(file, 'utf8'), relative, workspaceRoot),
      );
    }
  }
  return hits;
}

function productionGraphHits(workspaceRoot) {
  const hits = [];
  const seen = new Set();
  const queue = [...PRODUCTION_ENTRIES];
  while (queue.length > 0) {
    const relative = queue.shift();
    if (seen.has(relative)) {
      continue;
    }
    seen.add(relative);
    const absolute = path.join(workspaceRoot, relative);
    if (!existsSync(absolute) || !statSync(absolute).isFile()) {
      continue;
    }
    if (isTestkitFilesystemPath(absolute, workspaceRoot)) {
      hits.push(`生产入口依赖图到达 testkit：${relative}`);
      continue;
    }
    if (!isProductionSource(relative) && !PRODUCTION_ENTRIES.includes(relative)) {
      continue;
    }
    const text = readFileSync(absolute, 'utf8');
    for (const reason of extractUnsafeDynamicLoads(text, relative)) {
      hits.push(`${relative} 不得使用无法静态解析的动态加载（${reason}）`);
    }
    const specifiers = extractImportSpecifiers(text, relative);
    for (const specifier of specifiers) {
      if (isTestkitPackageSpecifier(specifier)) {
        hits.push(`${relative} 不得 import ${specifier}`);
        continue;
      }
      const resolved = resolveWorkspaceSpecifier(relative, specifier, workspaceRoot);
      if (resolved === null) {
        continue;
      }
      queue.push(posixRelative(workspaceRoot, resolved));
    }
  }
  return hits;
}

function packagedHits(workspaceRoot) {
  const hits = [];
  const outputs = [
    path.join(workspaceRoot, 'apps/desktop/out'),
    path.join(workspaceRoot, 'apps/desktop/.webpack'),
  ];
  for (const dir of outputs) {
    if (!existsSync(dir)) {
      continue;
    }
    for (const file of walk(dir, { includeNodeModules: true })) {
      const relative = posixRelative(workspaceRoot, file);
      if (file.endsWith('.swift')) {
        hits.push(`发布产物含 Swift 源：${relative}`);
      }
      if (relative.includes('golden-oracle') || isTestkitArchivePath(relative)) {
        hits.push(`发布产物含 golden-oracle / testkit：${relative}`);
      }
      if (file.endsWith('.asar')) {
        hits.push(...scanAsarArchive(file, relative, workspaceRoot));
        continue;
      }
      if (/\.(js|mjs|cjs|json)$/.test(file)) {
        hits.push(...markerHitsInText(readFileSync(file, 'utf8'), relative));
      }
    }
  }
  return hits;
}

export function scanAsarArchive(archivePath, label, workspaceRoot = defaultRoot) {
  const asar = loadAsarModule(workspaceRoot);
  const hits = [];
  const names = asar.listPackage(archivePath, { isPack: false });
  for (const name of names) {
    const posix = String(name).split(path.sep).join('/').replace(/^\//, '');
    if (posix.includes('golden-oracle') || isTestkitArchivePath(posix)) {
      hits.push(`发布产物 ${label} 含 golden-oracle / testkit：${posix}`);
    }
    if (posix.endsWith('.swift')) {
      hits.push(`发布产物 ${label} 含 Swift 源：${posix}`);
    }
    if (!/\.(js|mjs|cjs|json)$/.test(posix)) {
      continue;
    }
    try {
      const text = readAsarFile(asar, archivePath, posix, name);
      hits.push(...markerHitsInText(text, `${label}:${posix}`));
    } catch (error) {
      hits.push(`发布产物 ${label} 无法读取 ${posix}：${error instanceof Error ? error.message : String(error)}`);
    }
  }
  return hits;
}

function readAsarFile(asar, archivePath, posix, originalName) {
  const attempts = [...new Set([posix, String(originalName), `/${posix}`])];
  let lastError = null;
  for (const candidate of attempts) {
    try {
      return asar.extractFile(archivePath, candidate).toString('utf8');
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? new Error(`无法读取 ${posix}`);
}

function markerHitsInText(text, label) {
  const hits = [];
  for (const marker of PACKAGED_MARKERS) {
    if (text.includes(marker)) {
      hits.push(`发布产物含 ${marker}：${label}`);
      break;
    }
  }
  return hits;
}

function loadAsarModule(workspaceRoot) {
  const fromDesktop = path.join(workspaceRoot, 'apps/desktop/package.json');
  const fromRoot = path.join(workspaceRoot, 'package.json');
  for (const manifest of [fromDesktop, fromRoot]) {
    try {
      return createRequire(manifest)('@electron/asar');
    } catch {
      continue;
    }
  }
  throw new Error('无法加载 @electron/asar，无法检查 app.asar');
}

export function collectTestkitIsolationHits(workspaceRoot = defaultRoot) {
  return [
    ...packageHits(workspaceRoot),
    ...sourceImportHits(workspaceRoot),
    ...productionGraphHits(workspaceRoot),
    ...packagedHits(workspaceRoot),
  ];
}

const invokedDirectly =
  process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  const hits = collectTestkitIsolationHits();
  if (hits.length > 0) {
    console.error('testkit / oracle 隔离检查失败:');
    for (const hit of hits) {
      console.error(`- ${hit}`);
    }
    process.exit(1);
  }
  console.log('testkit / oracle 隔离检查通过');
}
