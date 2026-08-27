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

const ARRAY_QUERY_METHODS = new Set(['at', 'slice', 'concat', 'map', 'filter', 'flat']);
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
  const reflectApplyAliases = new Set();
  const callApplyAliases = new Set();
  const functionParams = new Map();
  const scopedBindingKinds = new WeakMap();
  const scopedArrayShapes = new WeakMap();

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
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped || !ts.isCallExpression(unwrapped)) {
      return undefined;
    }
    const bound = unwrapBindCall(unwrapped.expression);
    const callee = unwrapExpr(bound.target);
    if (isObjectAssignCallee(callee)) {
      const flat = flattenCallArguments(unwrapped.arguments);
      return flat.unresolvable && flat.items.length === 0 ? null : flat.items;
    }
    const access = staticMember(callee);
    if (access && (access.name === 'call' || access.name === 'apply') && isObjectAssignCallee(access.object)) {
      const borrowed = borrowedCallArgs(unwrapped, access.name);
      return borrowed ? borrowed.args : null;
    }
    return undefined;
  };

  const isArrayFromCallee = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    if (ts.isIdentifier(unwrapped) && arrayFromAliases.has(unwrapped.text)) {
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
    const access = staticMember(unwrapped);
    return Boolean(access?.name === 'of' && isObjectIdentifier(access.object, 'Array'));
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
      current = current.parent;
    }
    return null;
  };

  const scopedIdentifierKind = (ident) => {
    if (!ident || !ts.isIdentifier(ident)) {
      return undefined;
    }
    const decl = enclosingBindingName(ident);
    if (!decl) {
      return undefined;
    }
    if (!scopedBindingKinds.has(decl)) {
      return null;
    }
    return scopedBindingKinds.get(decl) ?? null;
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
      for (const el of unwrapped.elements) {
        if (ts.isOmittedExpression(el)) {
          continue;
        }
        if (ts.isSpreadElement(el)) {
          const inner = expandSpread(el.expression, nextSeen);
          if (inner === null) {
            complete = false;
            continue;
          }
          items.push(...inner.items);
          complete = complete && inner.complete;
          continue;
        }
        items.push(el);
      }
      return { items, complete };
    }
    const shape = shapeForValue(unwrapped);
    if (shape?.values) {
      return { items: shape.values.filter(Boolean), complete: !shape.opaque };
    }
    return null;
  };

  const flattenCallArguments = (args) => {
    const items = [];
    let unresolvable = false;
    for (const arg of args) {
      if (ts.isSpreadElement(arg)) {
        const expanded = expandSpread(arg.expression);
        if (expanded === null) {
          unresolvable = true;
          continue;
        }
        items.push(...expanded.items);
        if (!expanded.complete) {
          unresolvable = true;
        }
        continue;
      }
      items.push(arg);
    }
    return { items, unresolvable };
  };

  const unwrapBindCall = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped || !ts.isCallExpression(unwrapped)) {
      return { target: unwrapped, thisArg: null };
    }
    const access = staticMember(unwrapped.expression);
    if (access?.name !== 'bind') {
      return { target: unwrapped, thisArg: null };
    }
    return { target: access.object, thisArg: unwrapped.arguments[0] ?? null };
  };

  const borrowedCallArgs = (node, kind) => {
    const flat = flattenCallArguments(node.arguments);
    if (kind === 'call') {
      if (flat.unresolvable && flat.items.length === 0) {
        return null;
      }
      return {
        thisArg: flat.items[0] ?? null,
        args: flat.items.slice(1),
        unresolvable: flat.unresolvable,
      };
    }
    const restExpr = flat.items[1];
    const rest = restExpr ? expandSpread(restExpr) : { items: [], complete: true };
    if (rest === null) {
      return {
        thisArg: flat.items[0] ?? null,
        args: [],
        unresolvable: true,
      };
    }
    return {
      thisArg: flat.items[0] ?? null,
      args: rest.items,
      unresolvable: flat.unresolvable || !rest.complete,
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
    const flatArgs = flattenCallArguments(unwrapped.arguments);
    const argsUnresolvable = flatArgs.unresolvable;
    const args = flatArgs.items;
    if (aliased) {
      return { method: aliased.method, object: bound.thisArg ?? aliased.object, args, argsUnresolvable };
    }
    const access = staticMember(callee);
    if (access && (access.name === 'call' || access.name === 'apply')) {
      const methodAlias = resolveArrayMethodAlias(access.object);
      if (methodAlias) {
        const borrowed = borrowedCallArgs(unwrapped, access.name);
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
      if (reflectApplyAliases.has(unwrapped.text)) {
        reflectApplyAliases.add(toName);
      }
      if (callApplyAliases.has(unwrapped.text)) {
        callApplyAliases.add(toName);
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
      const stored = functionReturns.get(inheritedFactKey(key));
      if (stored) return stored;
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
      if (scoped !== undefined) {
        return scoped;
      }
      if (factories.has(expr.text)) {
        return 'factory';
      }
      if (requirers.has(expr.text)) {
        return 'requirer';
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
      if (scoped !== undefined) {
        return scoped;
      }
      if (factories.has(expr.text)) {
        return 'factory';
      }
      if (requirers.has(expr.text)) {
        return 'requirer';
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

  const shapeFromArrayOf = (args) => {
    const flat = flattenCallArguments(args);
    const kinds = [];
    const values = [];
    let opaque = flat.unresolvable;
    for (const arg of flat.items) {
      const kind = classifyExpr(arg);
      if (kind === null) {
        opaque = true;
      }
      kinds.push(kind);
      values.push(arg);
    }
    return shapeOf(opaque, kinds, values);
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
      if (isArrayFromCallee(unwrapped.expression)) {
        return shapeFromArrayFrom(unwrapped.arguments);
      }
      if (isArrayOfCallee(unwrapped.expression)) {
        return shapeFromArrayOf(unwrapped.arguments);
      }
      const callee = unwrapExpr(unwrapped.expression);
      if (isFunctionLikeNode(callee)) {
        return functionReturnShapeOf(callee);
      }
      const funcKey = callableReferenceKey(callee);
      if (funcKey) return functionReturnShapes.get(inheritedFactKey(funcKey));
      return undefined;
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
        if (indexed.candidates.length === 0 && LOADERISH_PROPERTIES.has(key)) {
          return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
        }
      }
      if (indexed.value) {
        return resolveObjectProperty(indexed.value, key, nextSeen);
      }
    }
    if (unwrapped && ts.isCallExpression(unwrapped)) {
      if (isObjectAssignCall(unwrapped)) {
        let fallback;
        const assignArgs = objectAssignArguments(unwrapped);
        if (assignArgs === null) {
          return { value: undefined, kind: 'requirer', shape: opaqueArrayShape(), callableKey: null };
        }
        for (const arg of assignArgs ?? []) {
          const sources = ts.isSpreadElement(arg)
            ? (expandSpread(arg.expression)?.items ?? [arg.expression])
            : [arg];
          for (const source of sources) {
            const resolved = resolveObjectProperty(source, key, nextSeen);
            if (!resolved) continue;
            if (dangerousPropertyKind(resolved) !== null) return resolved;
            fallback = resolved;
          }
        }
        return fallback;
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
      for (const property of unwrapped.properties) {
        if (ts.isSpreadAssignment(property)) {
          const spread = resolveObjectProperty(property.expression, key, nextSeen);
          if (spread) {
            resolved = spread;
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
        }
      }
      return resolved;
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
      }
    }
    const sourceKey = referenceKey(unwrapped);
    const storedValue = sourceKey === null ? undefined : valueExprs.get(sourceKey);
    if (storedValue && storedValue !== unwrapped) {
      const resolved = resolveObjectProperty(storedValue, key, nextSeen);
      if (resolved) return resolved;
    }
    const propertyKey = callableMemberKey(unwrapped, key);
    if (propertyKey === null) {
      return undefined;
    }
    const factKey = inheritedFactKey(propertyKey);
    const shape = arrayShapes.get(factKey);
    const kind = valueKinds.get(factKey);
    const storedFactValue = valueExprs.get(factKey);
    return shape || kind || hasReturnFacts(factKey) || storedFactValue
      ? { value: storedFactValue, kind: kind ?? null, shape, callableKey: factKey }
      : undefined;
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
      scopedBindingKinds.set(name, scopedKind);
      if (kind === 'factory') {
        factories.add(name.text);
      }
      if (kind === 'requirer') {
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
          scopedBindingKinds.set(bound, scopedKind);
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
        bindPattern(element.name, itemKind ?? inheritedKind, element.initializer);
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
      ts.isObjectLiteralExpression(unwrapped) ||
      ts.isNewExpression(unwrapped) ||
      isObjectAssignCall(unwrapped)
    ) {
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

  const bindCallArguments = (node) => {
    if (!ts.isCallExpression(node)) {
      return;
    }
    const key = callableReferenceKey(node.expression);
    const params = key === null ? undefined : functionParams.get(inheritedFactKey(key));
    if (!params) {
      return;
    }
    const flat = flattenCallArguments(node.arguments);
    const args = flat.items;
    params.forEach((paramName, i) => {
      const param = parameterFromName(paramName);
      if (param?.dotDotDotToken) {
        const restArgs = i < args.length ? args.slice(i) : [];
        const shape = shapeOf(
          restArgs.some((arg) => classifyExpr(arg) === null) || flat.unresolvable,
          restArgs.map((arg) => classifyExpr(arg)),
          restArgs,
        );
        bindPattern(paramName, null, undefined, shape);
        return;
      }
      if (i >= args.length) {
        return;
      }
      if (ts.isIdentifier(paramName) && !argumentCarriesTrackedFacts(args[i])) {
        return;
      }
      bindPattern(paramName, classifyExpr(args[i]), args[i]);
    });
  };

  const bindNode = (node) => {
    invalidateArrayMutation(node);
    registerFunctionReturn(node);
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
    ])}|${JSON.stringify([...arrayFromAliases])}|${JSON.stringify([...arrayOfAliases])}|${JSON.stringify([
      ...reflectApplyAliases,
    ])}|${JSON.stringify([
      ...callApplyAliases,
    ])}|${JSON.stringify(
      [...functionParams.entries()].map(([key, names]) => [
        key,
        names.map((name) => (ts.isIdentifier(name) ? name.text : String(name.kind))),
      ]),
    )}`;
  while (previous !== snapshot()) {
    previous = snapshot();
    bindNode(sourceFile);
  }

  const isLoaderArgument = (expr) => {
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
