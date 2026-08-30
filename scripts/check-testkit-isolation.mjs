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
const ARRAY_CALLBACK_METHODS = new Set([
  'forEach',
  'reduce',
  'reduceRight',
  'find',
  'findIndex',
  'findLast',
  'findLastIndex',
  'some',
  'every',
  'map',
  'filter',
  'flatMap',
]);
const ARRAY_ITERATOR_METHODS = new Set(['values', 'entries', 'keys']);
const ARRAY_METHODS = new Set([
  ...ARRAY_QUERY_METHODS,
  ...ARRAY_CALLBACK_METHODS,
  ...ARRAY_ITERATOR_METHODS,
]);
const LOADERISH_PROPERTIES = new Set(['get', 'require', 'createRequire', 'loader', 'req']);
const SAFE_OPAQUE_OBJECT_CONSTRUCTORS = new Set([
  'Map',
  'Set',
  'WeakMap',
  'WeakSet',
  'Date',
  'RegExp',
]);

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
  const generatorYieldExprs = new Map();
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
  const reflectGetAliases = new Set();
  const objectValuesAliases = new Set();
  const objectEntriesAliases = new Set();
  const objectGetOwnPropertyDescriptorAliases = new Set();
  const dynamicCodeAliases = new Set();
  const dynamicCodeBindings = new WeakSet();
  const mapGetReceivers = new WeakMap();
  const functionParams = new Map();
  const prototypeExprs = new Map();
  const scopedBindingKinds = new WeakMap();
  const scopedValueExprs = new WeakMap();
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

  const isKnownConcreteNewExpression = (value) => {
    const unwrapped = value ? unwrapExpr(value) : undefined;
    if (!unwrapped || !ts.isNewExpression(unwrapped)) {
      return false;
    }
    const constructor = unwrapExpr(unwrapped.expression);
    if (!constructor || !ts.isIdentifier(constructor)) {
      return false;
    }
    if (SAFE_OPAQUE_OBJECT_CONSTRUCTORS.has(constructor.text)) {
      return true;
    }
    return false;
  };

  const isConcreteIndexedValue = (value) => {
    const unwrapped = value ? unwrapExpr(value) : undefined;
    if (!unwrapped) {
      return false;
    }
    return Boolean(
        isFunctionLikeNode(unwrapped) ||
        ts.isObjectLiteralExpression(unwrapped) ||
        ts.isArrayLiteralExpression(unwrapped) ||
        isKnownConcreteNewExpression(unwrapped) ||
        ts.isStringLiteralLike(unwrapped) ||
        ts.isNumericLiteral(unwrapped) ||
        unwrapped.kind === ts.SyntaxKind.TrueKeyword ||
        unwrapped.kind === ts.SyntaxKind.FalseKeyword ||
        unwrapped.kind === ts.SyntaxKind.NullKeyword,
    );
  };

  const shapeHasOnlyConcreteValues = (shape) =>
    Boolean(
      shape &&
        shape.values &&
        shape.values.length > 0 &&
        shape.values.every((value) => value === undefined || isConcreteIndexedValue(value)),
    );

  const dangerousConcreteValueKind = (value) => {
    const kind = classifyExpr(value);
    if (kind === 'factory' || kind === 'requirer') {
      return kind;
    }
    const unwrapped = unwrapExpr(value);
    if (unwrapped && isFunctionLikeNode(unwrapped)) {
      const returned = functionReturnKind(unwrapped);
      return returned === 'factory' || returned === 'requirer' ? returned : null;
    }
    const returned = callableReturnKind(value);
    return returned === 'factory' || returned === 'requirer' ? returned : null;
  };

  const shapeHasDangerousConcreteValue = (shape) =>
    Boolean(
      shapeHasOnlyConcreteValues(shape) &&
        shape.values.some((value) => dangerousConcreteValueKind(value) !== null),
    );

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

  const isDynamicElementAccess = (expr) => {
    const unwrapped = unwrapExpr(expr);
    return Boolean(
        unwrapped &&
        ts.isElementAccessExpression(unwrapped) &&
        staticStringValue(unwrapped.argumentExpression) === null &&
        staticIndexValue(unwrapped.argumentExpression) === null,
    );
  };

  const directObjectPropertyValue = (objectExpr, propertyName, seen = new Set()) => {
    const object = unwrapExpr(objectExpr);
    if (!object || seen.has(object)) {
      return undefined;
    }
    const nextSeen = new Set(seen);
    nextSeen.add(object);
    if (ts.isObjectLiteralExpression(object)) {
      for (let i = object.properties.length - 1; i >= 0; i -= 1) {
        const property = object.properties[i];
        if (ts.isSpreadAssignment(property)) {
          const spread = directObjectPropertyValue(property.expression, propertyName, nextSeen);
          if (spread) {
            return spread;
          }
          continue;
        }
        const name = ts.isShorthandPropertyAssignment(property)
          ? property.name.text
          : ts.isPropertyAssignment(property) ||
              ts.isMethodDeclaration(property) ||
              ts.isGetAccessorDeclaration(property)
            ? propertyNameText(property.name)
            : null;
        if (name !== propertyName) {
          continue;
        }
        if (ts.isShorthandPropertyAssignment(property)) {
          return property.name;
        }
        if (ts.isPropertyAssignment(property)) {
          return property.initializer;
        }
        return property;
      }
      return undefined;
    }
    const key = referenceKey(object);
    const stored = key === null ? undefined : valueExprs.get(key);
    return stored && stored !== object
      ? directObjectPropertyValue(stored, propertyName, nextSeen)
      : undefined;
  };

  const isThisMemberChain = (expr) => {
    let current = unwrapExpr(expr);
    while (current) {
      if (current.kind === ts.SyntaxKind.ThisKeyword) {
        return true;
      }
      const member = staticMember(current);
      if (!member) {
        return false;
      }
      current = unwrapExpr(member.object);
    }
    return false;
  };

  const isCalleePosition = (expr) => {
    let current = expr;
    while (
      current?.parent &&
      (current.parent.kind === ts.SyntaxKind.ParenthesizedExpression ||
        current.parent.kind === ts.SyntaxKind.AsExpression ||
        current.parent.kind === ts.SyntaxKind.TypeAssertionExpression ||
        current.parent.kind === ts.SyntaxKind.NonNullExpression ||
        current.parent.kind === ts.SyntaxKind.SatisfiesExpression)
    ) {
      current = current.parent;
    }
    return Boolean(
      current?.parent &&
        ts.isCallExpression(current.parent) &&
        current.parent.expression === current,
    );
  };

  const isObjectIdentifier = (expr, name) => {
    const unwrapped = unwrapExpr(expr);
    return Boolean(unwrapped && ts.isIdentifier(unwrapped) && unwrapped.text === name);
  };

  const isGlobalObjectIdentifier = (expr) =>
    ['globalThis', 'global', 'window'].some((name) => isObjectIdentifier(expr, name));

  const isGlobalObjectValue = (expr, seen = new Set()) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped || seen.has(unwrapped)) {
      return false;
    }
    if (isGlobalObjectIdentifier(unwrapped)) {
      return true;
    }
    if (!ts.isIdentifier(unwrapped)) {
      return false;
    }
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    const bound = enclosingBindingName(unwrapped);
    const stored = bound ? scopedValueExprs.get(bound) : valueExprs.get(unwrapped.text);
    return Boolean(stored && stored !== unwrapped && isGlobalObjectValue(stored, nextSeen));
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

  const isReflectGetCallee = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    if (ts.isIdentifier(unwrapped) && reflectGetAliases.has(unwrapped.text)) {
      return true;
    }
    const key = referenceKey(unwrapped);
    if (key !== null && reflectGetAliases.has(key)) {
      return true;
    }
    const access = staticMember(unwrapped);
    if (access?.name === 'get' && isObjectIdentifier(access.object, 'Reflect')) {
      return true;
    }
    const resolved = access
      ? directObjectPropertyValue(access.object, access.name)
      : undefined;
    return Boolean(resolved && resolved !== unwrapped && isReflectGetCallee(resolved));
  };

  const isObjectValuesCallee = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    if (ts.isIdentifier(unwrapped) && objectValuesAliases.has(unwrapped.text)) {
      return true;
    }
    const key = referenceKey(unwrapped);
    if (key !== null && objectValuesAliases.has(key)) {
      return true;
    }
    const access = staticMember(unwrapped);
    if (access?.name === 'values' && isObjectIdentifier(access.object, 'Object')) {
      return true;
    }
    const resolved = access
      ? directObjectPropertyValue(access.object, access.name)
      : undefined;
    return Boolean(resolved && resolved !== unwrapped && isObjectValuesCallee(resolved));
  };

  const isObjectEntriesCallee = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    if (ts.isIdentifier(unwrapped) && objectEntriesAliases.has(unwrapped.text)) {
      return true;
    }
    const key = referenceKey(unwrapped);
    if (key !== null && objectEntriesAliases.has(key)) {
      return true;
    }
    const access = staticMember(unwrapped);
    if (access?.name === 'entries' && isObjectIdentifier(access.object, 'Object')) {
      return true;
    }
    const resolved = access
      ? directObjectPropertyValue(access.object, access.name)
      : undefined;
    return Boolean(resolved && resolved !== unwrapped && isObjectEntriesCallee(resolved));
  };

  const isObjectGetOwnPropertyDescriptorCallee = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped) {
      return false;
    }
    if (
      ts.isIdentifier(unwrapped) &&
      objectGetOwnPropertyDescriptorAliases.has(unwrapped.text)
    ) {
      return true;
    }
    const key = referenceKey(unwrapped);
    if (key !== null && objectGetOwnPropertyDescriptorAliases.has(key)) {
      return true;
    }
    const access = staticMember(unwrapped);
    if (access?.name === 'getOwnPropertyDescriptor' && isObjectIdentifier(access.object, 'Object')) {
      return true;
    }
    const resolved = access
      ? directObjectPropertyValue(access.object, access.name)
      : undefined;
    return Boolean(
      resolved && resolved !== unwrapped && isObjectGetOwnPropertyDescriptorCallee(resolved),
    );
  };

  const isDynamicCodeCallee = (expr, seen = new Set()) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped || seen.has(unwrapped)) {
      return false;
    }
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    if (ts.isIdentifier(unwrapped)) {
      const bound = enclosingBindingName(unwrapped);
      if (bound) {
        if (dynamicCodeBindings.has(bound)) {
          return true;
        }
        const stored = scopedValueExprs.get(bound);
        return Boolean(stored && stored !== unwrapped && isDynamicCodeCallee(stored, nextSeen));
      }
      return unwrapped.text === 'eval' || unwrapped.text === 'Function' || dynamicCodeAliases.has(unwrapped.text);
    }
    if (ts.isPropertyAccessExpression(unwrapped) || ts.isElementAccessExpression(unwrapped)) {
      const access = staticMember(unwrapped);
      if (access && (access.name === 'call' || access.name === 'apply')) {
        return isDynamicCodeCallee(access.object, nextSeen);
      }
      if (
        access &&
        (access.name === 'eval' || access.name === 'Function') &&
        isGlobalObjectValue(access.object)
      ) {
        return true;
      }
    }
    if (ts.isCallExpression(unwrapped)) {
      const access = staticMember(unwrapped.expression);
      if (access?.name === 'bind') {
        return isDynamicCodeCallee(access.object, nextSeen);
      }
    }
    return false;
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
        if (isDynamicCodeCallee(bindAccess.object)) {
          dynamicCodeAliases.add(toName);
        }
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
    if (isReflectGetCallee(unwrapped)) {
      reflectGetAliases.add(toName);
    }
    if (isObjectValuesCallee(unwrapped)) {
      objectValuesAliases.add(toName);
    }
    if (isObjectEntriesCallee(unwrapped)) {
      objectEntriesAliases.add(toName);
    }
    if (isObjectGetOwnPropertyDescriptorCallee(unwrapped)) {
      objectGetOwnPropertyDescriptorAliases.add(toName);
    }
    if (isCallOrApplyValue(unwrapped)) {
      callApplyAliases.add(toName);
    }
    if (isDynamicCodeCallee(unwrapped)) {
      dynamicCodeAliases.add(toName);
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
    const key = referenceKey(unwrapped);
    if (key !== null && callApplyAliases.has(key)) {
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
    const bound = unwrapBindCall(unwrapped);
    const target = bound.target && bound.target !== unwrapped ? bound.target : unwrapped;
    const access = staticMember(target);
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
    const bound = unwrapBindCall(unwrapped);
    if (bound.target && bound.target !== unwrapped) {
      const fromBind = resolveBorrowedCallTarget(bound.target, nextSeen);
      if (fromBind) {
        return fromBind;
      }
    }
    const access = staticMember(unwrapped);
    if (!access || (access.name !== 'call' && access.name !== 'apply')) {
      return null;
    }
    if (isFunctionPrototypeCallApply(unwrapped)) {
      return null;
    }
    const key = referenceKey(unwrapped);
    if (key !== null) {
      const stored = valueExprs.get(key);
      if (stored && stored !== unwrapped) {
        const nested = resolveBorrowedCallTarget(stored, nextSeen);
        if (nested) {
          return nested;
        }
      }
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
        targetExpr: resolveBorrowedCallTarget(calleeUnwrapped) ?? access.object,
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
    if (
      access &&
      ARRAY_METHODS.has(access.name) &&
      !(ARRAY_ITERATOR_METHODS.has(access.name) && isObjectIdentifier(access.object, 'Object'))
    ) {
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
      return {
        items: [...shape.values],
        complete: !shape.opaque,
        dropped: false,
      };
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
    if (
      access &&
      ARRAY_METHODS.has(access.name) &&
      !(ARRAY_ITERATOR_METHODS.has(access.name) && isObjectIdentifier(access.object, 'Object'))
    ) {
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
      if (reflectGetAliases.has(unwrapped.text)) {
        reflectGetAliases.add(toName);
      }
      if (objectValuesAliases.has(unwrapped.text)) {
        objectValuesAliases.add(toName);
      }
      if (objectEntriesAliases.has(unwrapped.text)) {
        objectEntriesAliases.add(toName);
      }
      if (objectGetOwnPropertyDescriptorAliases.has(unwrapped.text)) {
        objectGetOwnPropertyDescriptorAliases.add(toName);
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
        if (isCallOrApplyValue(bindAccess.object)) {
          callApplyAliases.add(toName);
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
    if (access.name === 'get' && isObjectIdentifier(object, 'Reflect')) {
      reflectGetAliases.add(toName);
    }
    if (access.name === 'values' && isObjectIdentifier(object, 'Object')) {
      objectValuesAliases.add(toName);
    }
    if (access.name === 'entries' && isObjectIdentifier(object, 'Object')) {
      objectEntriesAliases.add(toName);
    }
    if (
      access.name === 'getOwnPropertyDescriptor' &&
      isObjectIdentifier(object, 'Object')
    ) {
      objectGetOwnPropertyDescriptorAliases.add(toName);
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
    const mapResult = mapGetValue(unwrapped);
    if (mapResult) {
      if (mapResult.kind === 'factory' || mapResult.kind === 'requirer') {
        return mapResult.kind;
      }
      const valueKind = dangerousConcreteValueKind(mapResult.value);
      if (valueKind) {
        return valueKind;
      }
      return mapResult.unknown ? 'requirer' : null;
    }
    const iteratorShape = iteratorValueShape(unwrapped);
    if (iteratorShape) {
      const firstKind = iteratorShape.kinds[0];
      if (firstKind === 'factory' || firstKind === 'requirer') {
        return firstKind;
      }
      const firstValue = shapeValues(iteratorShape)[0];
      const valueKind = dangerousConcreteValueKind(firstValue);
      if (valueKind) {
        return valueKind;
      }
      if (shapeHasOnlyConcreteValues(iteratorShape)) {
        return null;
      }
      return iteratorShape.opaque ? dangerousShapeKind(iteratorShape) : null;
    }
    const index = staticArrayIndex(unwrapped);
    if (index !== null) {
      const shape = shapeForValue(unwrapped.expression);
      if (shape?.kinds[index] === 'factory' || shape?.kinds[index] === 'requirer') {
        return shape.kinds[index];
      }
      if (shape?.opaque) {
        const resolved = index >= 0 ? index : shape.kinds.length + index;
        if (resolved < 0 || resolved >= shape.kinds.length) {
          return null;
        }
        const selected = shapeValues(shape)[resolved];
        const selectedKind = isFunctionLikeNode(unwrapExpr(selected))
          ? functionReturnKind(unwrapExpr(selected))
          : callableReturnKind(selected);
        if (selectedKind === 'factory' || selectedKind === 'requirer') {
          return selectedKind;
        }
        if (!isConcreteIndexedValue(selected)) {
          const dangerous = dangerousShapeKind(shape);
          if (dangerous) return dangerous;
        }
      }
    }
    if (ts.isElementAccessExpression(unwrapped) && index === null) {
      const shape = shapeForValue(unwrapped.expression);
      if (shapeHasOnlyConcreteValues(shape)) {
        return null;
      }
      const dangerous = dangerousShapeKind(shape);
      if (dangerous) return dangerous;
    }
    if (ts.isCallExpression(unwrapped)) {
      const invocation = invocationOf(unwrapped);
      if (invocation && isReflectGetCallee(invocation.callee)) {
        const property = invocation.args.length >= 2 ? staticStringValue(invocation.args[1]) : null;
        if (invocation.unresolvable || invocation.args.length < 2 || property === null) {
          return 'requirer';
        }
        const resolved = resolveObjectProperty(invocation.args[0], property);
        const kind = dangerousPropertyKind(resolved);
        if (kind !== null) {
          return kind;
        }
        if (resolved?.returns === 'opaque') {
          return 'requirer';
        }
      }
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
            const resolved = atIndex >= 0 ? atIndex : shape.kinds.length + atIndex;
            if (resolved < 0 || resolved >= shape.kinds.length) {
              return null;
            }
            const selected = shapeValues(shape)[resolved];
            const selectedKind = isFunctionLikeNode(unwrapExpr(selected))
              ? functionReturnKind(unwrapExpr(selected))
              : callableReturnKind(selected);
            if (selectedKind === 'factory' || selectedKind === 'requirer') {
              return selectedKind;
            }
            if (!isConcreteIndexedValue(selected)) {
              const dangerous = dangerousShapeKind(shape);
              if (dangerous) return dangerous;
            }
          }
        }
        if (atIndex === null) {
          const shape = shapeForValue(parts.object);
          if (shapeHasOnlyConcreteValues(shape)) {
            return null;
          }
          const dangerous = dangerousShapeKind(shape);
          if (dangerous) return dangerous;
        }
      }
    }
    const member = staticMember(unwrapped);
    if (member) {
      if (
        isReflectGetCallee(unwrapped) ||
        isObjectValuesCallee(unwrapped) ||
        isObjectEntriesCallee(unwrapped) ||
        isObjectGetOwnPropertyDescriptorCallee(unwrapped)
      ) {
        return null;
      }
      const resolved = resolveObjectProperty(member.object, member.name, new Set([unwrapped]));
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

  const collectYieldExprs = (node) => {
    if (!node?.body) return [];
    const exprs = [];
    const visit = (child) => {
      if (child !== node && isFunctionLikeNode(child)) return;
      if (ts.isYieldExpression(child) && child.expression) {
        if (child.asteriskToken) {
          const expanded = expandSpread(child.expression);
          if (expanded) {
            exprs.push(...expanded.items);
          } else {
            exprs.push(child.expression);
          }
        } else {
          exprs.push(child.expression);
        }
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
    const yieldExprs = collectYieldExprs(funcNode);
    if (yieldExprs.length > 0) {
      generatorYieldExprs.set(key, yieldExprs);
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
    functionReturnExprs.has(key) ||
    generatorYieldExprs.has(key);

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
    if (generatorYieldExprs.has(sourceKey)) {
      generatorYieldExprs.set(targetKey, generatorYieldExprs.get(sourceKey));
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

  const classifyFunctionCall = (expr, seen = new Set()) => {
    if (!ts.isCallExpression(expr)) {
      return null;
    }
    const unwrappedCall = unwrapExpr(expr);
    if (!unwrappedCall || seen.has(unwrappedCall)) {
      return null;
    }
    const callee = unwrapExpr(unwrappedCall.expression);
    if (!callee) {
      return null;
    }
    const nextSeen = new Set(seen);
    nextSeen.add(unwrappedCall);
    const calleeKey = callableReferenceKey(callee);
    if (calleeKey !== null) {
      const mark = `fn:${calleeKey}`;
      if (nextSeen.has(mark)) {
        return null;
      }
      nextSeen.add(mark);
    }
    const access = staticMember(callee);
    if (
      isReflectGetCallee(callee) ||
      isObjectValuesCallee(callee) ||
      isObjectEntriesCallee(callee) ||
      isObjectGetOwnPropertyDescriptorCallee(callee)
    ) {
      return null;
    }
    const applied = applyTarget(unwrappedCall);
    if (applied === UNRESOLVABLE_TARGET) {
      return 'requirer';
    }
    if (applied) {
      return callableReturnKind(applied, nextSeen);
    }
    if (calleeKey !== null) {
      const factKey = inheritedFactKey(calleeKey);
      const stored = functionReturns.get(factKey);
      if (stored) {
        return stored;
      }
      const { source, args } = callSourceAndArgs(unwrappedCall);
      for (const returned of (functionReturnExprs.get(factKey) ?? []).flatMap((expr) =>
        expandBranchExprs(expr),
      )) {
        if (isCalleePosition(unwrappedCall) && isDynamicPropertyDerived(returned)) {
          return 'requirer';
        }
        for (const mapped of returnedValueCandidates(returned, source, args, nextSeen)) {
          let kind = callableReturnKind(mapped, nextSeen);
          if (kind !== 'factory' && kind !== 'requirer') {
            kind = returnedPropertyKind(returned, source, args, nextSeen);
          }
          if (kind === 'factory' || kind === 'requirer') {
            return kind === 'factory' ? 'requirer' : kind;
          }
        }
      }
    }
    const calleeKind = classifyCallee(callee);
    if (calleeKind === 'requirer') {
      return 'requirer';
    }
    if (access) {
      return callablePropertyReturnKind(resolveObjectProperty(access.object, access.name, nextSeen));
    }
    return callableReturnKind(callee, nextSeen);
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
    if (
      isDynamicElementAccess(expr) &&
      isCalleePosition(expr)
    ) {
      const shape = shapeForValue(expr.expression);
      if (shapeHasOnlyConcreteValues(shape)) {
        return shapeHasDangerousConcreteValue(shape) ? 'requirer' : null;
      }
      return 'requirer';
    }
    if (ts.isIdentifier(expr)) {
      if (isCalleePosition(expr)) {
        const bound = enclosingBindingName(expr);
        const stored = bound ? scopedValueExprs.get(bound) : valueExprs.get(expr.text);
        if (stored && isDynamicPropertyDerived(stored)) {
          return 'requirer';
        }
      }
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
      if (
        isReflectGetCallee(expr) ||
        isObjectValuesCallee(expr) ||
        isObjectEntriesCallee(expr) ||
        isObjectGetOwnPropertyDescriptorCallee(expr)
      ) {
        return null;
      }
      if (member.name === 'createRequire') {
        return 'factory';
      }
      if (member.name === 'require') {
        return 'requirer';
      }
      if (member.name === 'call' || member.name === 'apply') {
        const object = unwrapExpr(member.object);
        if (isDynamicPropertyDerived(object)) {
          return 'requirer';
        }
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
          const expanded = expandSpread(el.expression);
          if (expanded === null) {
            opaque = true;
            kinds.push(null);
            values.push(undefined);
            continue;
          }
          const spreadItems = [...expanded.items];
          if (!expanded.complete || expanded.dropped) {
            spreadItems.push(undefined);
            opaque = true;
          }
          for (const item of spreadItems) {
            const kind = item === undefined ? null : classifyExpr(item);
            opaque = opaque || kind === null;
            kinds.push(kind);
            values.push(item);
          }
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
    const source = shapeForValue(args[0]) ?? shapeFromArrayLike(args[0]) ?? shapeFromValue(args[0]);
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

  const shapeFromArrayLike = (valueExpr) => {
    const unwrapped = resolveAliasedValue(valueExpr);
    if (!unwrapped || !ts.isObjectLiteralExpression(unwrapped)) {
      return undefined;
    }
    const lengthExpr = objectLiteralPropertyValue(unwrapped, 'length');
    const lengthIsAccessor = Boolean(
      lengthExpr && ts.isGetAccessorDeclaration(unwrapExpr(lengthExpr)),
    );
    const staticLength = lengthIsAccessor ? null : staticIndexValue(lengthExpr);
    const length = staticLength;
    const numericPropertyIndexes = unwrapped.properties
      .map((property) => {
        const key = ts.isSpreadAssignment(property) ? null : propertyNameText(property.name);
        return key !== null && /^\d+$/.test(key) ? Number(key) : null;
      })
      .filter((index) => index !== null);
    const unknownLength = length === null;
    const slotCount = unknownLength
      ? Math.max(1, ...numericPropertyIndexes.map((index) => index + 1))
      : Math.max(0, length);
    const kinds = [];
    const values = [];
    let opaque = unknownLength || unwrapped.properties.some((property) => ts.isSpreadAssignment(property));
    const valueFromGetter = (value) => {
      const fn = unwrapExpr(value);
      if (!fn || !ts.isGetAccessorDeclaration(fn)) {
        return value;
      }
      const returns = collectReturnExprs(fn).flatMap((returned) => expandBranchExprs(returned));
      for (const returned of returns) {
        const kind = classifyExpr(returned);
        if (kind === 'factory' || kind === 'requirer') {
          return returned;
        }
      }
      return returns.length === 1 ? returns[0] : value;
    };
    for (let i = 0; i < slotCount; i += 1) {
      const value = objectLiteralPropertyValue(unwrapped, String(i));
      if (value === undefined || value?.opaque || value?.returns === 'opaque') {
        kinds.push(null);
        values.push(undefined);
        continue;
      }
      const resolvedValue = valueFromGetter(value);
      const kind = classifyExpr(resolvedValue);
      opaque = opaque || kind === null;
      kinds.push(kind);
      values.push(resolvedValue);
    }
    return shapeOf(opaque, kinds, values);
  };

  const shapeFromCollectionConstructor = (constructorName, args) => {
    if (!args || args.length === 0) {
      return shapeOf(false, [], []);
    }
    const source = shapeForValue(args[0]) ?? shapeFromArrayLike(args[0]) ?? shapeFromValue(args[0]);
    if (!source) {
      return opaqueArrayShape();
    }
    if (constructorName === 'Set') {
      return cloneShape(source);
    }
    const kinds = [];
    const values = [];
    let opaque = source.opaque;
    const sourceValues = shapeValues(source);
    for (let i = 0; i < source.kinds.length; i += 1) {
      const entry = sourceValues[i];
      const entryShape = entry ? shapeForValue(entry) : undefined;
      if (entryShape && entryShape.kinds.length >= 2) {
        const entryValues = shapeValues(entryShape);
        const value = entryValues[1];
        const kind = entryShape.kinds[1] ?? classifyExpr(value);
        opaque = opaque || entryShape.opaque || kind === null;
        kinds.push(kind);
        values.push(value);
      } else {
        opaque = true;
        kinds.push(null);
        values.push(undefined);
      }
    }
    return shapeOf(opaque, kinds, values);
  };

  const generatorShapeForCall = (expr) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped || !ts.isCallExpression(unwrapped)) {
      return undefined;
    }
    const key = callableReferenceKey(unwrapped.expression);
    if (key === null) {
      return undefined;
    }
    const yields = generatorYieldExprs.get(inheritedFactKey(key));
    return yields && yields.length > 0 ? shapeFromArrayItems(yields) : undefined;
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

  const shapeForValueImpl = (valueExpr) => {
    const unwrapped = valueExpr ? unwrapExpr(valueExpr) : undefined;
    if (!unwrapped) {
      return undefined;
    }
    if (ts.isArrayLiteralExpression(unwrapped)) {
      return shapeFromValue(unwrapped);
    }
    if (ts.isElementAccessExpression(unwrapped)) {
      return shapeFromIndexedValue(unwrapped);
    }
    const iterator = iteratorValueShape(unwrapped);
    if (iterator) {
      return iterator;
    }
    if (ts.isConditionalExpression(unwrapped)) {
      return mergeArrayShapes(shapeForValue(unwrapped.whenTrue), shapeForValue(unwrapped.whenFalse));
    }
    if (isLogicalBinary(unwrapped)) {
      return mergeArrayShapes(shapeForValue(unwrapped.left), shapeForValue(unwrapped.right));
    }
    if (ts.isCallExpression(unwrapped)) {
      const generator = generatorShapeForCall(unwrapped);
      if (generator) {
        return generator;
      }
      const parts = arrayCallParts(unwrapped);
      if (parts?.method === 'values') {
        return shapeForValue(parts.object) ?? shapeFromValue(parts.object);
      }
      if (parts?.method === 'at') {
        return shapeFromIndexedValue(unwrapped);
      }
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
      if (inv && isObjectValuesCallee(inv.callee)) {
        return shapeFromObjectEnumerable(inv.args[0], false);
      }
      if (inv && isObjectEntriesCallee(inv.callee)) {
        return shapeFromObjectEnumerable(inv.args[0], true);
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
    if (ts.isNewExpression(unwrapped)) {
      if (isArrayConstructorCallee(unwrapped.expression)) {
        return shapeFromArrayConstructor(unwrapped.arguments ?? []);
      }
      const constructor = unwrapExpr(unwrapped.expression);
      if (constructor && ts.isIdentifier(constructor) && (constructor.text === 'Set' || constructor.text === 'Map')) {
        return shapeFromCollectionConstructor(constructor.text, unwrapped.arguments ?? []);
      }
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
        const scoped = scopedArrayShapes.get(decl);
        const stored = arrayShapes.get(key);
        if (stored?.opaque) {
          return stored;
        }
        return scoped ?? stored;
      }
    }
    return key === null ? undefined : arrayShapes.get(key);
  };

  const shapeResolutionStack = new Set();

  const shapeForValue = (valueExpr) => {
    const unwrapped = valueExpr ? unwrapExpr(valueExpr) : undefined;
    if (!unwrapped || shapeResolutionStack.has(unwrapped)) {
      return undefined;
    }
    shapeResolutionStack.add(unwrapped);
    try {
      return shapeForValueImpl(valueExpr);
    } finally {
      shapeResolutionStack.delete(unwrapped);
    }
  };

  const iteratorShapeForExpression = (valueExpr, seen = new Set()) => {
    const unwrapped = valueExpr ? unwrapExpr(valueExpr) : undefined;
    if (!unwrapped || seen.has(unwrapped)) {
      return undefined;
    }
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);

    const aliased = resolveAliasedValue(unwrapped);
    if (aliased && aliased !== unwrapped) {
      const resolved = iteratorShapeForExpression(aliased, nextSeen);
      if (resolved) {
        return resolved;
      }
    }

    const parts = arrayCallParts(unwrapped);
    if (parts && ARRAY_ITERATOR_METHODS.has(parts.method)) {
      const sourceShape = shapeForValue(parts.object) ?? shapeFromValue(parts.object);
      if (!sourceShape) {
        return opaqueArrayShape();
      }
      if (parts.method === 'values') {
        return sourceShape;
      }
      if (parts.method === 'entries') {
        return shapeFromIteratorEntries(parts.object, sourceShape);
      }
      return shapeFromIteratorKeys(parts.object, sourceShape);
    }

    const generator = generatorShapeForCall(unwrapped);
    if (generator) {
      return generator;
    }

    if (ts.isCallExpression(unwrapped)) {
      const returned = returnExprsForCallable(unwrapped.expression, nextSeen);
      if (returned.length > 0) {
        const shapes = [];
        let unresolved = false;
        for (const expression of returned.flatMap((item) => expandBranchExprs(item))) {
          const shape = iteratorShapeForExpression(expression, nextSeen);
          if (shape) {
            shapes.push(shape);
          } else {
            unresolved = true;
          }
        }
        if (shapes.length > 0) {
          return mergeArrayShapes(...shapes, ...(unresolved ? [opaqueArrayShape()] : []));
        }
      }
    }

    return undefined;
  };

  const iteratorReceiverFromNextCall = (nextCall) => {
    const callee = unwrapExpr(nextCall?.expression);
    const resolveNextMember = (expr, seen = new Set()) => {
      const unwrapped = unwrapExpr(expr);
      if (!unwrapped || seen.has(unwrapped)) {
        return undefined;
      }
      const nextSeen = new Set(seen);
      nextSeen.add(unwrapped);
      const resolved = resolveAliasedValue(unwrapped);
      if (resolved && resolved !== unwrapped) {
        const fromAlias = resolveNextMember(resolved, nextSeen);
        if (fromAlias) {
          return fromAlias;
        }
      }
      const member = staticMember(unwrapped);
      if (member?.name === 'next') {
        return member.object;
      }
      const bound = unwrapBindCall(unwrapped);
      if (bound.target && bound.target !== unwrapped) {
        const fromBind = resolveNextMember(bound.target, nextSeen);
        if (fromBind) {
          return bound.thisArg ?? fromBind;
        }
      }
      return undefined;
    };

    const directReceiver = resolveNextMember(callee);
    if (directReceiver) {
      return directReceiver;
    }
    const access = staticMember(callee);
    if (!access || (access.name !== 'call' && access.name !== 'apply')) {
      return undefined;
    }
    const borrowedTarget = resolveBorrowedCallTarget(callee) ?? access.object;
    const targetReceiver = resolveNextMember(borrowedTarget);
    if (targetReceiver) {
      return targetReceiver;
    }
    return borrowedCallArgsFrom(nextCall.arguments, access.name)?.thisArg;
  };

  const iteratorSourceInfo = (valueExpr) => {
    const valueMember = staticMember(valueExpr);
    if (valueMember?.name !== 'value') {
      return undefined;
    }
    const nextCall = unwrapExpr(valueMember.object);
    if (!nextCall || !ts.isCallExpression(nextCall)) {
      return undefined;
    }
    const iterator = iteratorReceiverFromNextCall(nextCall);
    if (!iterator) {
      return undefined;
    }
    const sourceShape = iteratorShapeForExpression(iterator) ?? opaqueArrayShape();
    const parts = arrayCallParts(resolveAliasedValue(iterator));
    const method = parts?.method ?? 'values';
    return {
      method,
      receiver: parts?.object ?? iterator,
      sourceShape,
    };
  };

  const staticMapKeyValue = (expr) => {
    const string = staticStringValue(expr);
    if (string !== null) {
      return `string:${string}`;
    }
    const index = staticIndexValue(expr);
    if (index !== null) {
      return `number:${index}`;
    }
    const unwrapped = unwrapExpr(expr);
    if (unwrapped && ts.isIdentifier(unwrapped) && (requirers.has(unwrapped.text) || factories.has(unwrapped.text))) {
      return `reference:${unwrapped.text}`;
    }
    return null;
  };

  const mapEntryShapes = (receiver) => {
    const unwrapped = resolveAliasedValue(receiver);
    if (!unwrapped || !ts.isNewExpression(unwrapped)) {
      return undefined;
    }
    const constructor = unwrapExpr(unwrapped.expression);
    if (!constructor || !ts.isIdentifier(constructor) || constructor.text !== 'Map') {
      return undefined;
    }
    if (!unwrapped.arguments || unwrapped.arguments.length === 0) {
      return [];
    }
    const source =
      shapeForValue(unwrapped.arguments[0]) ??
      shapeFromArrayLike(unwrapped.arguments[0]) ??
      shapeFromValue(unwrapped.arguments[0]);
    const shapeHasKnownConcreteValues = (shape) =>
      Boolean(
        shape &&
          shape.values &&
          shape.values.length === shape.kinds.length &&
          shape.values.length > 0 &&
          shape.values.every((value) => value !== undefined && isConcreteIndexedValue(value)),
      );
    const sourceOpaque = source.opaque && !shapeHasKnownConcreteValues(source);
    const values = shapeValues(source);
    if (values.length === 0 && source.opaque) {
      return [{ key: undefined, value: undefined, keyKind: null, valueKind: null, opaque: true }];
    }
    return values.map((entry, index) => {
      const entryShape = entry ? shapeForValue(entry) : undefined;
      if (!entryShape || entryShape.kinds.length < 2) {
        return {
          key: undefined,
          value: undefined,
          keyKind: null,
          valueKind: null,
          opaque: true,
        };
      }
      const entryValues = shapeValues(entryShape);
      return {
        key: entryValues[0],
        value: entryValues[1],
        keyKind: entryShape.kinds[0] ?? classifyExpr(entryValues[0]),
        valueKind: entryShape.kinds[1] ?? classifyExpr(entryValues[1]),
        opaque: sourceOpaque || (entryShape.opaque && !shapeHasKnownConcreteValues(entryShape)),
        index,
      };
    });
  };

  const mapReceiverCandidates = (valueExpr, seen = new Set()) => {
    const unwrapped = valueExpr ? unwrapExpr(valueExpr) : undefined;
    if (!unwrapped || seen.has(unwrapped)) {
      return { receivers: [], uncertain: false, recognized: false };
    }
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    const merge = (parts) => {
      const receivers = [];
      let uncertain = false;
      let recognized = false;
      for (const part of parts) {
        if (!part) {
          continue;
        }
        for (const receiver of part.receivers) {
          if (!receivers.includes(receiver)) {
            receivers.push(receiver);
          }
        }
        uncertain = uncertain || part.uncertain;
        recognized = recognized || part.recognized;
        if (!part.recognized) {
          uncertain = true;
        }
      }
      return { receivers, uncertain, recognized };
    };

    const aliased = resolveAliasedValue(unwrapped);
    if (aliased && aliased !== unwrapped) {
      return mapReceiverCandidates(aliased, nextSeen);
    }
    if (ts.isNewExpression(unwrapped)) {
      const constructor = unwrapExpr(unwrapped.expression);
      if (constructor && ts.isIdentifier(constructor) && constructor.text === 'Map') {
        return { receivers: [unwrapped], uncertain: false, recognized: true };
      }
      return { receivers: [], uncertain: false, recognized: false };
    }
    if (ts.isConditionalExpression(unwrapped) || isLogicalBinary(unwrapped)) {
      return merge(
        (ts.isConditionalExpression(unwrapped)
          ? [unwrapped.whenTrue, unwrapped.whenFalse]
          : [unwrapped.left, unwrapped.right]
        ).map((branch) =>
          mapReceiverCandidates(branch, nextSeen),
        ),
      );
    }
    if (isFunctionLikeNode(unwrapped)) {
      const returned = collectReturnExprs(unwrapped).flatMap((item) =>
        expandBranchExprs(item, nextSeen),
      );
      if (returned.length > 0) {
        return merge(returned.map((item) => mapReceiverCandidates(item, nextSeen)));
      }
      return { receivers: [], uncertain: false, recognized: false };
    }
    if (ts.isCallExpression(unwrapped)) {
      const invocation = invocationOf(unwrapped);
      if (invocation && isReflectGetCallee(invocation.callee)) {
        const property = invocation.args.length >= 2 ? staticStringValue(invocation.args[1]) : null;
        if (property !== null && invocation.args[0]) {
          const reflected = resolveObjectProperty(invocation.args[0], property, nextSeen);
          if (reflected?.value && reflected.value !== unwrapped) {
            const nested = mapReceiverCandidates(reflected.value, nextSeen);
            if (nested.recognized) {
              return nested;
            }
          }
          if (property === 'get') {
            const nested = mapReceiverCandidates(invocation.args[0], nextSeen);
            if (nested.recognized) {
              return nested;
            }
          }
          if (reflected?.returns === 'opaque') {
            return { receivers: [], uncertain: false, recognized: false };
          }
        }
      }
      const indexed = indexedElement(unwrapped);
      if (indexed) {
        const candidates = indexed.value ? [indexed.value] : indexed.candidates;
        if (candidates.length > 0) {
          return merge(candidates.map((candidate) =>
            mapReceiverCandidates(candidate, nextSeen),
          ));
        }
      }
      const returned = returnExprsForCallable(unwrapped.expression, nextSeen);
      if (returned.length > 0) {
        return merge(
          returned.flatMap((item) => expandBranchExprs(item, nextSeen)).map((item) =>
            mapReceiverCandidates(item, nextSeen),
          ),
        );
      }
      return { receivers: [], uncertain: false, recognized: false };
    }
    const indexed = indexedElement(unwrapped);
    if (indexed) {
      const candidates = indexed.value ? [indexed.value] : indexed.candidates;
      if (candidates.length > 0) {
        return merge(candidates.map((candidate) =>
          mapReceiverCandidates(candidate, nextSeen),
        ));
      }
    }
    if (ts.isIdentifier(unwrapped)) {
      const binding = enclosingBindingName(unwrapped);
      const stored = binding ? scopedValueExprs.get(binding) : valueExprs.get(unwrapped.text);
      if (stored && stored !== unwrapped) {
        return mapReceiverCandidates(stored, nextSeen);
      }
    }
    const member = staticMember(unwrapped);
    if (member) {
      const resolved = resolveObjectProperty(member.object, member.name, nextSeen);
      if (resolved?.value && resolved.value !== unwrapped) {
        return mapReceiverCandidates(resolved.value, nextSeen);
      }
      if (resolved?.returns === 'opaque') {
        return { receivers: [], uncertain: false, recognized: false };
      }
    }
    return { receivers: [], uncertain: false, recognized: false };
  };

  const mapGetTargetInfo = (target, seen = new Set()) => {
    const unwrapped = target ? unwrapExpr(target) : undefined;
    if (!unwrapped || seen.has(unwrapped)) {
      return undefined;
    }
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);

    const bound = unwrapBindCall(unwrapped);
    if (bound.target && bound.target !== unwrapped) {
      const nested = mapGetTargetInfo(bound.target, nextSeen);
      if (nested) {
        return {
          ...nested,
          boundArgs: [...nested.boundArgs, ...bound.boundArgs],
        };
      }
    }

    const member = staticMember(unwrapped);
    if (member?.name === 'get') {
      const candidates = mapReceiverCandidates(member.object, nextSeen);
      if (candidates.recognized) {
        return {
          receivers: candidates.receivers,
          receiver: candidates.receivers[0],
          uncertain: candidates.uncertain,
          boundArgs: [],
        };
      }
    }
    if (member) {
      const resolved = resolveObjectProperty(member.object, member.name, nextSeen);
      if (resolved?.value && resolved.value !== unwrapped) {
        const nested = mapGetTargetInfo(resolved.value, nextSeen);
        if (nested) {
          return nested;
        }
      }
    }
    if (ts.isNewExpression(unwrapped)) {
      const constructor = unwrapExpr(unwrapped.expression);
      if (constructor && ts.isIdentifier(constructor) && constructor.text === 'Map') {
        return { receivers: [unwrapped], receiver: unwrapped, uncertain: false, boundArgs: [] };
      }
    }

    if (ts.isCallExpression(unwrapped)) {
      const invocation = invocationOf(unwrapped);
      if (invocation && isReflectGetCallee(invocation.callee)) {
        const property = invocation.args.length >= 2 ? staticStringValue(invocation.args[1]) : null;
        const receiver = invocation.args[0] ? resolveAliasedValue(invocation.args[0]) : undefined;
        if (property === 'get') {
          const candidates = mapReceiverCandidates(receiver, nextSeen);
          if (candidates.recognized) {
            return {
              receivers: candidates.receivers,
              receiver: candidates.receivers[0],
              uncertain: candidates.uncertain,
              boundArgs: [],
            };
          }
        }
      }
      for (const returned of returnExprsForCallable(unwrapped.expression, nextSeen)) {
        const nested = mapGetTargetInfo(returned, nextSeen);
        if (nested) {
          return nested;
        }
      }
    }

    if (ts.isIdentifier(unwrapped)) {
      const binding = enclosingBindingName(unwrapped);
      const destructuredReceiver = binding ? mapGetReceivers.get(binding) : undefined;
      if (destructuredReceiver) {
        const candidates = mapReceiverCandidates(destructuredReceiver, nextSeen);
        return {
          receivers: candidates.receivers,
          receiver: candidates.receivers[0],
          uncertain: candidates.uncertain,
          recognized: candidates.recognized,
          boundArgs: [],
        };
      }
      const aliased = resolveAliasedValue(unwrapped);
      if (aliased && aliased !== unwrapped) {
        const nested = mapGetTargetInfo(aliased, nextSeen);
        if (nested) {
          return nested;
        }
      }
    }
    return undefined;
  };

  const mapGetValue = (expr) => {
    if (!ts.isCallExpression(expr)) {
      return undefined;
    }
    const callee = unwrapExpr(expr.expression);
    const applied = callApplyBindingFrom(callee, expr.arguments);
    const targetInfo = applied
      ? mapGetTargetInfo(applied.targetExpr)
      : mapGetTargetInfo(callee);
    if (!targetInfo) {
      return undefined;
    }
    const args = applied ? applied.fnArgs : [...targetInfo.boundArgs, ...expr.arguments];
    const unresolvable = Boolean(applied?.unresolvable) || args.length < 1;
    const receivers = targetInfo.receivers?.length
      ? targetInfo.receivers.map((receiver) => resolveAliasedValue(receiver))
      : targetInfo.receiver
        ? [resolveAliasedValue(targetInfo.receiver)]
        : [];
    const maps = receivers.filter((receiver) => {
      const constructor = receiver ? unwrapExpr(receiver.expression) : undefined;
      return (
        receiver &&
        ts.isNewExpression(receiver) &&
        constructor &&
        ts.isIdentifier(constructor) &&
        constructor.text === 'Map'
      );
    });
    if (maps.length === 0 && !targetInfo.uncertain) {
      return undefined;
    }
    if (unresolvable) {
      return { unknown: true, kind: null, value: undefined };
    }
    const requested = args[0];
    const keyValue = requested ? staticMapKeyValue(requested) : null;
    if (keyValue === null) {
      return { unknown: true, kind: null, value: undefined };
    }
    let uncertain = false;
    let matched = false;
    let matchedKind = null;
    let matchedValue;
    for (const receiver of maps) {
      const entries = mapEntryShapes(receiver);
      for (const entry of entries ?? []) {
        const entryKey = staticMapKeyValue(entry.key);
        if (entryKey === null || entry.opaque) {
          uncertain = true;
          continue;
        }
        if (entryKey === keyValue) {
          const kind = entry.valueKind ?? classifyExpr(entry.value);
          if (kind === 'factory' || kind === 'requirer') {
            return { unknown: false, kind, value: entry.value };
          }
          matched = true;
          matchedKind = kind;
          matchedValue = entry.value;
        }
      }
    }
    uncertain = uncertain || Boolean(targetInfo.uncertain);
    return {
      unknown: uncertain,
      kind: matched ? matchedKind : null,
      value: matched ? matchedValue : undefined,
    };
  };

  const shapeFromIteratorEntries = (receiver, sourceShape) => {
    const mapEntries = mapEntryShapes(receiver);
    if (mapEntries) {
      const first = mapEntries[0];
      return first
        ? shapeOf(first.opaque, [first.keyKind, first.valueKind], [first.key, first.value])
        : shapeOf(false, [], []);
    }
    const unwrapped = resolveAliasedValue(receiver);
    if (unwrapped && ts.isNewExpression(unwrapped)) {
      const constructor = unwrapExpr(unwrapped.expression);
      if (constructor && ts.isIdentifier(constructor) && constructor.text === 'Set') {
        const value = shapeValues(sourceShape)[0];
        return shapeOf(sourceShape.opaque, [sourceShape.kinds[0], sourceShape.kinds[0]], [value, value]);
      }
    }
    if (unwrapped && ts.isArrayLiteralExpression(unwrapped)) {
      const value = shapeValues(sourceShape)[0];
      return shapeOf(
        sourceShape.opaque,
        [null, sourceShape.kinds[0] ?? classifyExpr(value)],
        [ts.factory.createNumericLiteral('0'), value],
      );
    }
    if (sourceShape.kinds.length === 0 && !sourceShape.opaque) {
      return shapeOf(false, [], []);
    }
    return shapeOf(true, [null, null], [undefined, undefined]);
  };

  const shapeFromIteratorKeys = (receiver, sourceShape) => {
    const mapEntries = mapEntryShapes(receiver);
    if (mapEntries) {
      return shapeOf(
        mapEntries.some((entry) => entry.opaque),
        mapEntries.map((entry) => entry.keyKind),
        mapEntries.map((entry) => entry.key),
      );
    }
    const unwrapped = resolveAliasedValue(receiver);
    if (unwrapped && ts.isArrayLiteralExpression(unwrapped)) {
      return shapeOf(
        false,
        sourceShape.kinds.map(() => null),
        sourceShape.kinds.map((_, index) => ts.factory.createNumericLiteral(String(index))),
      );
    }
    if (unwrapped && ts.isNewExpression(unwrapped)) {
      const constructor = unwrapExpr(unwrapped.expression);
      if (constructor && ts.isIdentifier(constructor) && constructor.text === 'Set') {
        return cloneShape(sourceShape);
      }
    }
    return opaqueArrayShape();
  };

  const iteratorValueShape = (valueExpr) => {
    const info = iteratorSourceInfo(valueExpr);
    return info?.sourceShape;
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
      const constructor = unwrapExpr(unwrapped.expression);
      if (
        constructor &&
        ts.isIdentifier(constructor) &&
        SAFE_OPAQUE_OBJECT_CONSTRUCTORS.has(constructor.text)
      ) {
        return false;
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

  const opaqueLoaderishProperty = (key) =>
    LOADERISH_PROPERTIES.has(key)
      ? { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' }
      : undefined;

  const opaqueObjectProperty = () => ({
    value: undefined,
    kind: null,
    shape: undefined,
    callableKey: null,
    returns: 'opaque',
  });

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
      const trusted = resolved !== null ? shapeValues(shape)[resolved] : undefined;
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

  const shapeFromIndexedValue = (expr) => {
    const indexed = indexedElement(expr);
    if (!indexed) {
      return undefined;
    }
    const selected = indexed.value ? [indexed.value] : [];
    const candidates = selected.length > 0 ? selected : indexed.candidates;
    const nestedShapes = candidates
      .map((candidate) => shapeForValue(candidate))
      .filter(Boolean);
    if (nestedShapes.length === 0) {
      if (indexed.value && isConcreteIndexedValue(indexed.value)) {
        return undefined;
      }
      return indexed.opaque ? opaqueArrayShape() : undefined;
    }
    const merged = mergeArrayShapes(...nestedShapes);
    if (!merged) {
      return indexed.opaque ? opaqueArrayShape() : undefined;
    }
    return indexed.opaque
      ? shapeOf(true, [...merged.kinds], [...shapeValues(merged)])
      : merged;
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
        if (indexed.candidates.length === 0) {
          if (LOADERISH_PROPERTIES.has(key)) {
            return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
          }
          return opaqueObjectProperty();
        }
      }
      if (indexed.value) {
        return resolveObjectProperty(indexed.value, key, nextSeen);
      }
    }
    if (unwrapped && ts.isCallExpression(unwrapped)) {
      const created = invocationOf(unwrapped);
      if (created && isReflectGetCallee(created.callee)) {
        if (created.unresolvable || created.args.length < 2) {
          return LOADERISH_PROPERTIES.has(key)
            ? { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' }
            : opaqueObjectProperty();
        }
        const property = staticStringValue(created.args[1]);
        if (property === null) {
          return LOADERISH_PROPERTIES.has(key)
            ? { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' }
            : opaqueObjectProperty();
        }
        const reflected = resolveObjectProperty(created.args[0], property, nextSeen);
        if (reflected?.value) {
          const nested = resolveObjectProperty(reflected.value, key, nextSeen);
          if (nested) {
            return nested;
          }
        }
        if (reflected?.returns === 'opaque') {
          return LOADERISH_PROPERTIES.has(key)
            ? { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' }
            : opaqueObjectProperty();
        }
        return undefined;
      }
      if (created && isObjectGetOwnPropertyDescriptorCallee(created.callee)) {
        if (created.unresolvable || created.args.length < 2) {
          return LOADERISH_PROPERTIES.has(key)
            ? { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' }
            : opaqueObjectProperty();
        }
        const property = staticStringValue(created.args[1]);
        if (property === null) {
          return LOADERISH_PROPERTIES.has(key)
            ? { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' }
            : opaqueObjectProperty();
        }
        const descriptor = resolveObjectProperty(created.args[0], property, nextSeen);
        if (descriptor) {
          if (key === 'value' || key === 'get' || key === 'set') {
            return descriptor;
          }
          if (descriptor.returns === 'opaque') {
            return LOADERISH_PROPERTIES.has(key)
              ? { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' }
              : opaqueObjectProperty();
          }
        }
        if (LOADERISH_PROPERTIES.has(key)) {
          return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
        }
        return undefined;
      }
      if (isObjectAssignCall(unwrapped)) {
        const assignArgs = objectAssignArguments(unwrapped);
        if (assignArgs === null) {
          if (LOADERISH_PROPERTIES.has(key)) {
            return { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' };
          }
          return opaqueObjectProperty();
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
        if (opaqueSource) {
          return opaqueObjectProperty();
        }
        return fallback;
      }
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
      const callSource = created?.callee ?? unwrapped.expression;
      const callArgs = created?.args ?? [];
      const returnExprs = returnExprsForCallable(callSource, nextSeen);
      let fallback;
      for (const returnExpr of returnExprs) {
        for (const candidate of returnedValueCandidates(
          returnExpr,
          callSource,
          callArgs,
          nextSeen,
        )) {
          const resolved = mapReturnedProperty(
            resolveObjectProperty(candidate, key, nextSeen),
            callSource,
            callArgs,
          );
          if (!resolved) continue;
          if (dangerousPropertyKind(resolved) !== null) return resolved;
          if (!fallback) fallback = resolved;
        }
      }
      if (fallback) {
        return fallback;
      }
      if (returnExprs.length > 0 && returnExprs.every((returned) => isConcreteIndexedValue(returned))) {
        return undefined;
      }
      const calleeMember = staticMember(unwrapped.expression);
      if (calleeMember && LOADERISH_PROPERTIES.has(calleeMember.name)) {
        const safeReceiver = isThisMemberChain(calleeMember.object) || (
          ts.isNewExpression(unwrapExpr(calleeMember.object)) &&
          ts.isIdentifier(unwrapExpr(calleeMember.object).expression) &&
          SAFE_OPAQUE_OBJECT_CONSTRUCTORS.has(unwrapExpr(calleeMember.object).expression.text)
        );
        if (safeReceiver) {
          return undefined;
        }
        return LOADERISH_PROPERTIES.has(key)
          ? { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' }
          : opaqueObjectProperty();
      }
      return opaqueLoaderishProperty(key) ?? opaqueObjectProperty();
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
      if (opaqueSpread) {
        return opaqueObjectProperty();
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
      if (!parent && isOpaqueObjectSource(member.object) && !isThisMemberChain(member.object)) {
        return LOADERISH_PROPERTIES.has(key)
          ? { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' }
          : opaqueObjectProperty();
      }
      if (parent?.returns === 'opaque') {
        return LOADERISH_PROPERTIES.has(key)
          ? { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' }
          : opaqueObjectProperty();
      }
    }
    if (ts.isIdentifier(unwrapped)) {
      const decl = enclosingBindingName(unwrapped);
      if (decl) {
        const stored = scopedValueExprs.get(decl);
        if (stored && stored !== unwrapped) {
          const resolved = resolveObjectProperty(stored, key, nextSeen);
          if (resolved) {
            return resolved;
          }
        }
        if (parameterFromName(decl)) {
          return objectPrototypeProperty(key);
        }
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
    if (
      isOpaqueObjectSource(unwrapped) &&
      !isThisMemberChain(unwrapped) &&
      !isConcreteIndexedValue(unwrapped) &&
      !(
        ts.isNewExpression(unwrapped) &&
        ts.isIdentifier(unwrapped.expression) &&
        SAFE_OPAQUE_OBJECT_CONSTRUCTORS.has(unwrapped.expression.text)
      )
    ) {
      return LOADERISH_PROPERTIES.has(key)
        ? { value: undefined, kind: null, shape: undefined, callableKey: null, returns: 'requirer' }
        : opaqueObjectProperty();
    }
    return objectPrototypeProperty(key);
  };

  const returnExprsForCallable = (valueExpr, seen = new Set()) => {
    const unwrapped = valueExpr ? unwrapExpr(valueExpr) : undefined;
    if (!unwrapped || seen.has(unwrapped)) return [];
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    if (
      isReflectGetCallee(unwrapped) ||
      isObjectValuesCallee(unwrapped) ||
      isObjectEntriesCallee(unwrapped) ||
      isObjectGetOwnPropertyDescriptorCallee(unwrapped)
    ) {
      return [];
    }
    if (isFunctionLikeNode(unwrapped)) {
      return collectReturnExprs(unwrapped);
    }
    const access = staticMember(unwrapped);
    if (access?.name === 'call' || access?.name === 'apply') {
      return returnExprsForCallable(access.object, nextSeen);
    }
    const indexed = indexedElement(unwrapped);
    if (indexed) {
      const candidates = indexed.value ? [indexed.value] : indexed.candidates;
      for (const candidate of candidates) {
        const returned = returnExprsForCallable(candidate, nextSeen);
        if (returned.length > 0) {
          return returned;
        }
      }
    }
    if (access) {
      const resolved = resolveObjectProperty(access.object, access.name, nextSeen);
      if (resolved?.accessorValue && resolved.value) {
        return [resolved.value];
      }
      if (resolved?.callableKey) {
        const stored = functionReturnExprs.get(inheritedFactKey(resolved.callableKey));
        if (stored && stored.length > 0) {
          return stored;
        }
      }
      if (resolved?.value) {
        return returnExprsForCallable(resolved.value, nextSeen);
      }
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
    if (
      isReflectGetCallee(unwrapped) ||
      isObjectValuesCallee(unwrapped) ||
      isObjectEntriesCallee(unwrapped) ||
      isObjectGetOwnPropertyDescriptorCallee(unwrapped)
    ) {
      return null;
    }
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
      for (const returned of returnExprsForCallable(unwrapped.expression, nextSeen)) {
        const kind = callableReturnKind(returned, nextSeen);
        if (kind === 'factory' || kind === 'requirer') return kind;
      }
      const invoked = classifyFunctionCall(unwrapped, nextSeen);
      if (invoked === 'factory' || invoked === 'requirer') {
        return invoked;
      }
      return null;
    }
    const member = staticMember(unwrapped);
    if (member) {
      const resolved = resolveObjectProperty(member.object, member.name, nextSeen);
      const kind = callablePropertyReturnKind(resolved);
      if (kind !== null) return kind;
      if (resolved?.value) return callableReturnKind(resolved.value, nextSeen);
    }
    const callableKey = callableReferenceKey(unwrapped);
    if (callableKey === null) return null;
    return functionReturns.get(inheritedFactKey(callableKey)) ?? null;
  };

  const calleeFunctionNode = (callee, seen = new Set()) => {
    const unwrapped = unwrapExpr(callee);
    if (!unwrapped || seen.has(unwrapped)) {
      return null;
    }
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    if (isFunctionLikeNode(unwrapped)) {
      return unwrapped;
    }
    if (ts.isIdentifier(unwrapped)) {
      const decl = enclosingBindingName(unwrapped);
      if (!decl) {
        return null;
      }
      if (decl.parent && isFunctionLikeNode(decl.parent) && decl.parent.name === decl) {
        return decl.parent;
      }
      const stored = scopedValueExprs.get(decl);
      if (!stored) {
        return null;
      }
      return calleeFunctionNode(stored, nextSeen);
    }
    const member = staticMember(unwrapped);
    if (!member) {
      return null;
    }
    const resolved = resolveObjectProperty(member.object, member.name);
    const value = resolved?.value ? unwrapExpr(resolved.value) : undefined;
    return value ? calleeFunctionNode(value, nextSeen) : null;
  };

  const extractBoundValue = (pattern, decl, arg, arrayValues) => {
    if (!pattern || decl === undefined) {
      return undefined;
    }
    if (ts.isIdentifier(pattern)) {
      return pattern === decl ? arg : undefined;
    }
    if (ts.isObjectBindingPattern(pattern)) {
      for (const element of pattern.elements) {
        if (!ts.isBindingElement(element)) {
          continue;
        }
        if (element.dotDotDotToken) {
          const extracted = extractBoundValue(element.name, decl, arg, arrayValues);
          if (extracted !== undefined) {
            return extracted;
          }
          continue;
        }
        const elementKey = bindingElementKey(element);
        const source = elementKey !== null && arg !== undefined ? resolveObjectProperty(arg, elementKey) : undefined;
        const nestedArg = source?.value;
        if (nestedArg === undefined) {
          continue;
        }
        const extracted = extractBoundValue(element.name, decl, nestedArg);
        if (extracted !== undefined) {
          return extracted;
        }
      }
      return undefined;
    }
    if (ts.isArrayBindingPattern(pattern)) {
      const values = arrayValues ?? (arg === undefined ? [] : shapeValues(shapeFromValue(arg)));
      let index = 0;
      for (const element of pattern.elements) {
        if (ts.isOmittedExpression(element)) {
          index += 1;
          continue;
        }
        if (!ts.isBindingElement(element)) {
          continue;
        }
        if (element.dotDotDotToken) {
          const restValues = values.slice(index);
          const extracted = extractBoundValue(element.name, decl, restValues[0], restValues);
          if (extracted !== undefined) {
            return extracted;
          }
          continue;
        }
        const itemValue = values[index];
        if (itemValue !== undefined) {
          const extracted = extractBoundValue(element.name, decl, itemValue);
          if (extracted !== undefined) {
            return extracted;
          }
        }
        index += 1;
      }
    }
    return undefined;
  };

  const argumentForReturnedParam = (returned, callee, args, seen = new Set()) => {
    const unwrapped = unwrapExpr(returned);
    if (!unwrapped || !Array.isArray(args)) {
      return returned;
    }
    if (seen.has(unwrapped)) {
      return returned;
    }
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    const member = staticMember(unwrapped);
    if (member) {
      const mappedObject = argumentForReturnedParam(member.object, callee, args, nextSeen);
      if (mappedObject !== member.object) {
        const resolved = resolveObjectProperty(mappedObject, member.name, nextSeen);
        if (resolved?.value) {
          return argumentForReturnedParam(resolved.value, callee, args, nextSeen);
        }
      }
      return returned;
    }
    if (!ts.isIdentifier(unwrapped)) {
      return returned;
    }
    const func = calleeFunctionNode(callee);
    if (!func?.parameters) {
      return returned;
    }
    const decl = enclosingBindingName(unwrapped);
    if (!decl) {
      return returned;
    }
    for (let i = 0; i < func.parameters.length; i += 1) {
      const param = func.parameters[i];
      const paramName = param.name;
      if (param.dotDotDotToken) {
        const restArgs = args.slice(i);
        if (ts.isArrayBindingPattern(paramName)) {
          const extracted = extractBoundValue(paramName, decl, undefined, restArgs);
          if (extracted !== undefined) {
            return extracted;
          }
          continue;
        }
        if (ts.isObjectBindingPattern(paramName)) {
          for (const restArg of restArgs) {
            const extracted = extractBoundValue(paramName, decl, restArg);
            if (extracted !== undefined) {
              return extracted;
            }
          }
          continue;
        }
        if (ts.isIdentifier(paramName) && paramName === decl) {
          return restArgs[0] ?? returned;
        }
        continue;
      }
      const extracted = extractBoundValue(paramName, decl, args[i]);
      if (extracted !== undefined) {
        return extracted;
      }
    }
    const stored = scopedValueExprs.get(decl);
    if (stored && stored !== unwrapped) {
      const mapped = argumentForReturnedParam(stored, callee, args, nextSeen);
      return mapped;
    }
    return returned;
  };

  const callSourceAndArgs = (callExpr) => {
    const bound = unwrapBindCall(callExpr.expression);
    const innerCallee = unwrapExpr(bound.target);
    const rawArgs = [...bound.boundArgs, ...callExpr.arguments];
    const applied = callApplyBindingFrom(innerCallee, rawArgs);
    const source = applied?.targetExpr ? unwrapExpr(applied.targetExpr) : innerCallee;
    const args = applied ? applied.fnArgs : flattenCallArguments(rawArgs).items;
    return { source, args };
  };

  const returnedValueCandidates = (returned, callee, args, seen = new Set()) => {
    const unwrapped = unwrapExpr(returned);
    if (!unwrapped || seen.has(unwrapped)) {
      return [];
    }
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    const branches = ts.isConditionalExpression(unwrapped) || isLogicalBinary(unwrapped)
      ? expandBranchExprs(unwrapped, seen)
      : [unwrapped];
    const candidates = [];
    for (const branch of branches) {
      const mapped = argumentForReturnedParam(branch, callee, args, seen);
      candidates.push(mapped);
      const nestedCall = unwrapExpr(mapped);
      if (!nestedCall || !ts.isCallExpression(nestedCall)) {
        continue;
      }
      const nested = callSourceAndArgs(nestedCall);
      for (const nestedReturn of returnExprsForCallable(nested.source, nextSeen)) {
        candidates.push(
          ...returnedValueCandidates(nestedReturn, nested.source, nested.args, nextSeen),
        );
      }
    }
    return candidates.filter((candidate, index) => candidates.indexOf(candidate) === index);
  };

  const mapReturnedProperty = (resolved, callee, args) => {
    if (!resolved?.value) {
      return resolved;
    }
    const mapped = argumentForReturnedParam(resolved.value, callee, args);
    if (mapped === resolved.value) {
      return resolved;
    }
    return {
      ...resolved,
      value: mapped,
      kind: classifyExpr(mapped),
      shape: knownArrayShape(mapped),
      callableKey: null,
    };
  };

  const returnedPropertyKind = (returned, callee, args, seen = new Set()) => {
    const unwrapped = unwrapExpr(returned);
    if (!unwrapped || seen.has(unwrapped)) {
      return null;
    }
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    const branches = ts.isConditionalExpression(unwrapped) || isLogicalBinary(unwrapped)
      ? expandBranchExprs(unwrapped, seen)
      : [unwrapped];
    for (const branch of branches) {
      const member = staticMember(branch);
      if (member) {
        const mappedObject = argumentForReturnedParam(member.object, callee, args, nextSeen);
        const resolved = resolveObjectProperty(mappedObject, member.name, nextSeen);
        const kind = dangerousPropertyKind(resolved);
        if (kind !== null) {
          return kind;
        }
        if (resolved?.returns === 'requirer') {
          return 'requirer';
        }
      }
      const call = unwrapExpr(branch);
      if (call && ts.isCallExpression(call)) {
        const nested = callSourceAndArgs(call);
        for (const nestedReturn of returnExprsForCallable(nested.source, nextSeen)) {
          const kind = returnedPropertyKind(nestedReturn, nested.source, nested.args, nextSeen);
          if (kind !== null) {
            return kind;
          }
        }
      }
    }
    return null;
  };

  const isDynamicPropertyDerived = (valueExpr, seen = new Set()) => {
    const unwrapped = valueExpr ? unwrapExpr(valueExpr) : undefined;
    if (!unwrapped || seen.has(unwrapped)) {
      return false;
    }
    if (isDynamicElementAccess(unwrapped)) {
      const shape = shapeForValue(unwrapped.expression);
      if (shapeHasOnlyConcreteValues(shape)) {
        return shapeHasDangerousConcreteValue(shape);
      }
      return true;
    }
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    const aliased = resolveAliasedValue(unwrapped);
    if (aliased && aliased !== unwrapped && isDynamicPropertyDerived(aliased, nextSeen)) {
      return true;
    }
    if (ts.isConditionalExpression(unwrapped) || isLogicalBinary(unwrapped)) {
      return expandBranchExprs(unwrapped).some((branch) =>
        isDynamicPropertyDerived(branch, nextSeen),
      );
    }
    if (ts.isCallExpression(unwrapped)) {
      const { source, args } = callSourceAndArgs(unwrapped);
      return returnExprsForCallable(source, nextSeen).some((returned) =>
        returnedValueCandidates(returned, source, args, nextSeen).some((candidate) =>
          isDynamicPropertyDerived(candidate, nextSeen),
        ),
      );
    }
    const member = staticMember(unwrapped);
    if (member) {
      const resolved = resolveObjectProperty(member.object, member.name, nextSeen);
      return Boolean(resolved?.value && isDynamicPropertyDerived(resolved.value, nextSeen));
    }
    return false;
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
      const { source, args } = callSourceAndArgs(unwrapped);
      for (const returned of returnExprsForCallable(source, nextSeen)) {
        for (const candidate of returnedValueCandidates(returned, source, args, nextSeen)) {
          registerCallableFacts(targetKey, candidate, nextSeen);
        }
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
    for (const [key, exprs] of [...generatorYieldExprs.entries()]) {
      if (key.startsWith(prefix)) {
        generatorYieldExprs.set(`${targetBase}.${key.slice(prefix.length)}`, exprs);
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
      const isConstDeclaration = Boolean(
        name.parent &&
          ts.isVariableDeclaration(name.parent) &&
          name.parent.name === name &&
          name.parent.parent &&
          ts.isVariableDeclarationList(name.parent.parent) &&
          Boolean(name.parent.parent.flags & ts.NodeFlags.Const),
      );
      if (valueExpr && isDynamicCodeCallee(valueExpr)) {
        dynamicCodeBindings.add(name);
      }
      if (!scopedKind && isConstDeclaration) {
        scopedBindingKinds.delete(name);
        valueKinds.delete(name.text);
      }
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
      const unwrappedValue = valueExpr ? unwrapExpr(valueExpr) : undefined;
      if (!declaredHere) {
        const bound = enclosingBindingName(name);
        if (bound && bound !== name) {
          if (scopedKind) {
            scopedBindingKinds.set(bound, scopedKind);
          }
          if (shape) {
            scopedArrayShapes.set(bound, shape);
          }
          if (unwrappedValue) {
            scopedValueExprs.set(bound, unwrappedValue);
          }
        }
      }
      if (unwrappedValue) {
        valueExprs.set(name.text, unwrappedValue);
        scopedValueExprs.set(name, unwrappedValue);
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
        if (
          ts.isIdentifier(element.name) &&
          ARRAY_METHODS.has(key) &&
          !(ARRAY_ITERATOR_METHODS.has(key) && isObjectIdentifier(valueExpr, 'Object'))
        ) {
          arrayMethodAliases.set(element.name.text, { method: key, object: valueExpr });
        }
        if (
          ts.isIdentifier(element.name) &&
          (key === 'eval' || key === 'Function') &&
          isGlobalObjectValue(valueExpr)
        ) {
          dynamicCodeAliases.add(element.name.text);
          dynamicCodeBindings.add(element.name);
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
        if (ts.isIdentifier(element.name) && key === 'get' && isObjectIdentifier(valueExpr, 'Reflect')) {
          reflectGetAliases.add(element.name.text);
        }
        if (ts.isIdentifier(element.name) && key === 'values' && isObjectIdentifier(valueExpr, 'Object')) {
          objectValuesAliases.add(element.name.text);
        }
        if (ts.isIdentifier(element.name) && key === 'entries' && isObjectIdentifier(valueExpr, 'Object')) {
          objectEntriesAliases.add(element.name.text);
        }
        if (
          ts.isIdentifier(element.name) &&
          key === 'getOwnPropertyDescriptor' &&
          isObjectIdentifier(valueExpr, 'Object')
        ) {
          objectGetOwnPropertyDescriptorAliases.add(element.name.text);
        }
        if (ts.isIdentifier(element.name) && (key === 'call' || key === 'apply')) {
          callApplyAliases.add(element.name.text);
        }
        if (ts.isIdentifier(element.name) && key === 'get') {
          const candidates = mapReceiverCandidates(valueExpr);
          if (candidates.receivers.length > 0) {
            mapGetReceivers.set(element.name, valueExpr);
          }
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
      const decl = enclosingBindingName(unwrapped);
      if (decl) {
        const stored = scopedValueExprs.get(decl);
        if (stored && stored !== unwrapped) {
          const nextSeen = new Set(seen);
          nextSeen.add(unwrapped);
          return resolveAliasedValue(stored, nextSeen);
        }
        return unwrapped;
      }
      const stored = valueExprs.get(unwrapped.text);
      if (stored && stored !== unwrapped) {
        const nextSeen = new Set(seen);
        nextSeen.add(unwrapped);
        return resolveAliasedValue(stored, nextSeen);
      }
    }
    return unwrapped;
  };

  const objectEnumerableEntries = (expr, seen = new Set()) => {
    const unwrapped = resolveAliasedValue(expr);
    if (!unwrapped || seen.has(unwrapped)) {
      return null;
    }
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    if (ts.isArrayLiteralExpression(unwrapped)) {
      const entries = [];
      let opaque = false;
      for (const [index, element] of unwrapped.elements.entries()) {
        if (ts.isOmittedExpression(element)) {
          continue;
        }
        if (ts.isSpreadElement(element)) {
          const nested = objectEnumerableEntries(element.expression, nextSeen);
          if (!nested) {
            opaque = true;
          } else {
            entries.push(...nested.entries);
            opaque = opaque || nested.opaque;
          }
          continue;
        }
        entries.push({ key: String(index), value: element });
      }
      return {
        opaque,
        entries,
      };
    }
    if (ts.isObjectLiteralExpression(unwrapped)) {
      const entries = [];
      let opaque = false;
      for (const property of unwrapped.properties) {
        if (ts.isSpreadAssignment(property)) {
          const nested = objectEnumerableEntries(property.expression, nextSeen);
          if (!nested) {
            opaque = true;
          } else {
            entries.push(...nested.entries);
            opaque = opaque || nested.opaque;
          }
          continue;
        }
        let key = null;
        let value;
        if (ts.isShorthandPropertyAssignment(property)) {
          key = property.name.text;
          value = property.name;
        } else if (ts.isPropertyAssignment(property)) {
          key = propertyNameText(property.name);
          value = property.initializer;
        } else if (ts.isMethodDeclaration(property) || ts.isGetAccessorDeclaration(property)) {
          key = propertyNameText(property.name);
          value = property;
        }
        if (key !== null && value) {
          entries.push({ key, value });
        }
      }
      return { opaque, entries };
    }
    if (isObjectAssignCall(unwrapped)) {
      const args = objectAssignArguments(unwrapped);
      if (args === null) {
        return { opaque: true, entries: [] };
      }
      const entries = [];
      let opaque = false;
      for (const arg of args ?? []) {
        const sources = ts.isSpreadElement(arg)
          ? expandSpread(arg.expression)?.items ?? []
          : [arg];
        if (ts.isSpreadElement(arg) && sources.length === 0) {
          opaque = true;
          continue;
        }
        for (const source of sources) {
          const nested = objectEnumerableEntries(source, nextSeen);
          if (!nested) {
            opaque = true;
          } else {
            entries.push(...nested.entries);
            opaque = opaque || nested.opaque;
          }
        }
      }
      return { opaque, entries };
    }
    return null;
  };

  const shapeFromObjectEnumerable = (expr, entriesMode) => {
    const enumerable = objectEnumerableEntries(expr);
    if (!enumerable) {
      return opaqueArrayShape();
    }
    const values = entriesMode
      ? enumerable.entries.map(({ key, value }) =>
          ts.factory.createArrayLiteralExpression([
            ts.factory.createStringLiteral(key),
            value,
          ]),
        )
      : enumerable.entries.map(({ value }) => value);
    const kinds = values.map((value) => classifyExpr(value));
    return shapeOf(enumerable.opaque || kinds.some((kind) => kind === null), kinds, values);
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
    const descriptorFactIsPreferred = (fact, expr) => {
      if (fact?.returns === 'requirer' || fact?.kind === 'factory' || fact?.kind === 'requirer') {
        return true;
      }
      const params = paramsForCallable(fact?.value ?? expr);
      return Boolean(params?.some((name) => isParamCalleeUsed(name)));
    };
    const pickDescriptorPropertyFacts = (candidates, options) => {
      let fallback;
      for (const candidate of candidates) {
        const fact = descriptorPropertyFact(candidate, options);
        if (!fact) {
          continue;
        }
        if (descriptorFactIsPreferred(fact, candidate)) {
          return fact;
        }
        fallback ??= fact;
      }
      return fallback;
    };
    const descriptorPropertyFact = (expr, { followGetterReturns = false } = {}) => {
      const fn = unwrapExpr(expr);
      if (!fn) {
        return undefined;
      }
      if (followGetterReturns && isFunctionLikeNode(fn)) {
        const returns = collectReturnExprs(fn).flatMap((returned) => expandBranchExprs(returned));
        if (returns.length > 0) {
          return pickDescriptorPropertyFacts(returns);
        }
      }
      if (ts.isConditionalExpression(fn) || isLogicalBinary(fn)) {
        return pickDescriptorPropertyFacts(expandBranchExprs(fn));
      }
      const kind =
        classifyExpr(expr) ??
        (isFunctionLikeNode(fn) ? functionReturnKind(fn) : null);
      if (kind === 'factory' || kind === 'requirer') {
        return {
          value: expr,
          kind: kind === 'factory' ? 'requirer' : kind,
          shape: knownArrayShape(expr),
          callableKey: null,
        };
      }
      const aliased = resolveAliasedValue(fn);
      const key = callableReferenceKey(fn);
      const factKey = key === null ? null : inheritedFactKey(key);
      if (
        isFunctionLikeNode(fn) ||
        (aliased && isFunctionLikeNode(aliased)) ||
        (factKey !== null && (functionParams.has(factKey) || hasReturnFacts(factKey)))
      ) {
        return {
          value: expr,
          kind: null,
          shape: knownArrayShape(expr),
          callableKey: factKey,
        };
      }
      return undefined;
    };
    const getter = objectLiteralPropertyValue(literal, 'get');
    if (getter && !getter?.opaque) {
      const fromGetter = descriptorPropertyFact(getter, { followGetterReturns: true });
      if (fromGetter) {
        return { ...fromGetter, accessorValue: true };
      }
    }
    const value = objectLiteralPropertyValue(literal, 'value');
    if (value && !value?.opaque) {
      const fromValue = pickDescriptorPropertyFacts(expandBranchExprs(value));
      if (fromValue) {
        return fromValue;
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

  const paramsForCallable = (expr, seen = new Set()) => {
    const unwrapped = unwrapExpr(expr);
    if (!unwrapped || seen.has(unwrapped)) {
      return undefined;
    }
    const nextSeen = new Set(seen);
    nextSeen.add(unwrapped);
    const pickParams = (candidates) => {
      let fallback;
      for (const candidate of candidates) {
        const params = paramsForCallable(candidate, nextSeen);
        if (!params) {
          continue;
        }
        if (params.some((name) => isParamCalleeUsed(name))) {
          return params;
        }
        fallback ??= params;
      }
      return fallback;
    };
    const aliased = resolveAliasedValue(unwrapped);
    if (aliased && aliased !== unwrapped) {
      const fromAlias = paramsForCallable(aliased, nextSeen);
      if (fromAlias) {
        return fromAlias;
      }
    }
    if (ts.isConditionalExpression(unwrapped) || isLogicalBinary(unwrapped)) {
      return pickParams(expandBranchExprs(unwrapped));
    }
    const indexed = indexedElement(unwrapped);
    if (indexed) {
      const candidates = indexed.value ? [indexed.value] : indexed.candidates;
      const fromIndexed = pickParams(candidates);
      if (fromIndexed) {
        return fromIndexed;
      }
    }
    if (isFunctionLikeNode(unwrapped)) {
      if (ts.isGetAccessorDeclaration(unwrapped)) {
        return pickParams(collectReturnExprs(unwrapped));
      }
      return unwrapped.parameters.map((param) => param.name);
    }
    const bound = unwrapBindCall(unwrapped);
    if (bound.target && bound.target !== unwrapped) {
      const fromBind = paramsForCallable(bound.target, nextSeen);
      if (fromBind) {
        return fromBind;
      }
    }
    const member = staticMember(unwrapped);
    if (member) {
      const resolved = resolveObjectProperty(member.object, member.name, nextSeen);
      if (resolved?.callableKey) {
        const stored = functionParams.get(inheritedFactKey(resolved.callableKey));
        if (stored) {
          return stored;
        }
      }
      if (resolved?.value) {
        const fromValue = paramsForCallable(resolved.value, nextSeen);
        if (fromValue) {
          return fromValue;
        }
      }
    }
    if (ts.isCallExpression(unwrapped)) {
      const { source, args } = callSourceAndArgs(unwrapped);
      const calleeKey = source ? callableReferenceKey(source) : null;
      if (calleeKey !== null) {
        const mark = `fn:${calleeKey}`;
        if (nextSeen.has(mark)) {
          return undefined;
        }
        nextSeen.add(mark);
      }
      const mapped = returnExprsForCallable(source, nextSeen).flatMap((returned) =>
        returnedValueCandidates(returned, source, args, nextSeen),
      );
      const fromReturn = pickParams(mapped);
      if (fromReturn) {
        return fromReturn;
      }
    }
    if (ts.isIdentifier(unwrapped)) {
      const decl = enclosingBindingName(unwrapped);
      if (decl && parameterFromName(decl)) {
        const stored = scopedValueExprs.get(decl);
        if (stored && stored !== unwrapped) {
          return paramsForCallable(stored, nextSeen);
        }
        return undefined;
      }
    }
    const key = callableReferenceKey(unwrapped);
    if (key !== null) {
      const stored = functionParams.get(inheritedFactKey(key));
      if (stored) {
        return stored;
      }
    }
    return undefined;
  };

  const callBindingFor = (node) => {
    if (!ts.isCallExpression(node)) {
      return null;
    }
    const bound = unwrapBindCall(node.expression);
    const callee = unwrapExpr(bound.target);
    const rawArgs = [...bound.boundArgs, ...node.arguments];
    const applied = callApplyBindingFrom(callee, rawArgs);
    if (applied) {
      const target = applied.targetExpr ? unwrapExpr(applied.targetExpr) : null;
      return {
        key: target ? callableReferenceKey(target) : null,
        args: applied.fnArgs,
        unresolvable: applied.unresolvable,
        params: paramsForCallable(target),
      };
    }
    const flat = flattenCallArguments(rawArgs);
    return {
      key: callableReferenceKey(callee),
      args: flat.items,
      unresolvable: flat.unresolvable,
      params: paramsForCallable(callee),
    };
  };

  const callbackSourceShape = (sourceExpr) =>
    shapeForValue(sourceExpr) ?? shapeFromArrayLike(sourceExpr) ?? shapeFromValue(sourceExpr);

  const bindCallbackParameterToShape = (paramName, shape, calleeUsed = isParamCalleeUsed(paramName)) => {
    if (!paramName || !shape) {
      return;
    }
    const values = shapeValues(shape);
    for (let index = 0; index < shape.kinds.length; index += 1) {
      const value = values[index];
      const kind = shape.kinds[index];
      if (value === undefined && kind === null) {
        continue;
      }
      bindPattern(paramName, kind, value);
    }
    if (
      shape.opaque &&
      calleeUsed &&
      !shapeHasOnlyConcreteValues(shape)
    ) {
      bindPattern(paramName, 'requirer', undefined);
    }
  };

  const bindingPatternUsedAsCallee = (pattern, body) => {
    if (!pattern || !body) {
      return false;
    }
    const bindings = [];
    const collectBindings = (node) => {
      if (ts.isIdentifier(node)) {
        bindings.push(node);
        return;
      }
      if (ts.isObjectBindingPattern(node) || ts.isArrayBindingPattern(node)) {
        for (const element of node.elements) {
          if (ts.isBindingElement(element)) {
            collectBindings(element.name);
          }
        }
      }
    };
    collectBindings(pattern);
    let used = false;
    const visit = (node) => {
      if (used) {
        return;
      }
      if (
        ts.isIdentifier(node) &&
        isCalleePosition(node) &&
        bindings.some((binding) => enclosingBindingName(node) === binding)
      ) {
        used = true;
        return;
      }
      ts.forEachChild(node, visit);
    };
    visit(body);
    return used;
  };

  const bindArrayCallbackArguments = (node) => {
    if (!ts.isCallExpression(node)) {
      return;
    }
    let method = null;
    let sourceExpr;
    let args = [];
    const parts = arrayCallParts(node);
    if (parts && ARRAY_CALLBACK_METHODS.has(parts.method)) {
      method = parts.method;
      sourceExpr = parts.object;
      args = parts.args;
    } else {
      const invocation = invocationOf(node);
      if (!invocation || !isArrayFromCallee(invocation.callee)) {
        return;
      }
      method = 'from';
      sourceExpr = invocation.args[0];
      args = invocation.args;
    }
    const callbackIndex = method === 'from' ? 1 : 0;
    const callback = args[callbackIndex];
    const params = callback ? paramsForCallable(callback) : undefined;
    if (!params || !params[0]) {
      return;
    }
    const shape = callbackSourceShape(sourceExpr);
    if (method === 'reduce' || method === 'reduceRight') {
      if (args[1]) {
        bindPattern(params[0], classifyExpr(args[1]), args[1]);
      } else {
        bindCallbackParameterToShape(params[0], shape);
      }
      if (params[1]) {
        bindCallbackParameterToShape(params[1], shape);
      }
      return;
    }
    bindCallbackParameterToShape(params[0], shape);
    if (method === 'forEach' && params[1]) {
      const mapEntries = mapEntryShapes(sourceExpr);
      const receiver = resolveAliasedValue(sourceExpr);
      const constructor = receiver && ts.isNewExpression(receiver)
        ? unwrapExpr(receiver.expression)
        : undefined;
      const source = mapEntries
        ? shapeFromIteratorKeys(sourceExpr, shape)
        : constructor && ts.isIdentifier(constructor) && constructor.text === 'Set'
          ? shape
          : undefined;
      if (source) {
        bindCallbackParameterToShape(params[1], source);
      }
    }
  };

  const bindForOfVariable = (node) => {
    if (!ts.isForOfStatement(node)) {
      return;
    }
    const initializer = node.initializer;
    if (!ts.isVariableDeclarationList(initializer)) {
      return;
    }
    const shape = callbackSourceShape(node.expression);
    for (const declaration of initializer.declarations) {
      bindCallbackParameterToShape(
        declaration.name,
        shape,
        bindingPatternUsedAsCallee(declaration.name, node.statement),
      );
    }
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
    const params = binding.params ?? (key === null ? undefined : functionParams.get(inheritedFactKey(key)));
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
        const scopedArgument = unwrapExpr(args[i]);
        if (scopedArgument) {
          scopedValueExprs.set(paramName, scopedArgument);
        }
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
    bindArrayCallbackArguments(node);
    bindForOfVariable(node);
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
    )}|${JSON.stringify(
      [...generatorYieldExprs.entries()].map(([key, exprs]) => [
        key,
        exprs.map((expr) => [expr.kind, expr.pos]),
      ]),
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
      [...reflectGetAliases],
    )}|${JSON.stringify([...objectValuesAliases])}|${JSON.stringify([
      ...objectEntriesAliases,
    ])}|${JSON.stringify([
      ...objectGetOwnPropertyDescriptorAliases,
    ])}|${JSON.stringify([...dynamicCodeAliases])}|${JSON.stringify(
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

  const isDynamicCodeInvocation = (node) => {
    if (!ts.isCallExpression(node) && !ts.isNewExpression(node)) {
      return false;
    }
    if (isDynamicCodeCallee(node.expression)) {
      return true;
    }
    if (!ts.isCallExpression(node)) {
      return false;
    }
    const target = applyTarget(node);
    return target !== UNRESOLVABLE_TARGET && Boolean(target) && isDynamicCodeCallee(target);
  };

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
    loads.push(
      ...loadsFromNode(
        node,
        classifyCallee,
        staticStringValue,
        classifyExpr,
        isLoaderArgument,
        isDynamicCodeInvocation,
      ),
    );
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
  isDynamicCodeInvocation = null,
) {
  const loads = [];
  if (
    (ts.isCallExpression(node) || ts.isNewExpression(node)) &&
    isDynamicCodeInvocation &&
    isDynamicCodeInvocation(node)
  ) {
    loads.push({ kind: 'unsafe', reason: '动态代码执行' });
    return loads;
  }
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
        if (specifier === 'node:module' || specifier === 'module') {
          loads.push({ kind: 'unsafe', reason: '动态 import node:module' });
        }
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
  if (ts.isIdentifier(name) || ts.isStringLiteralLike(name) || ts.isNumericLiteral(name)) {
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
  const dependencyFields = [
    'dependencies',
    'devDependencies',
    'optionalDependencies',
    'peerDependencies',
  ];
  const bundledDependencyFields = ['bundledDependencies', 'bundleDependencies'];
  const productionManifests = [
    'apps/desktop/package.json',
    'packages/wire/package.json',
    'packages/domain/package.json',
    'packages/contracts/package.json',
  ];
  for (const relative of productionManifests) {
    const json = JSON.parse(readFileSync(path.join(workspaceRoot, relative), 'utf8'));
    for (const field of dependencyFields) {
      if (json[field]?.[FORBIDDEN_PACKAGE]) {
        hits.push(`${relative} ${field} 不得依赖 ${FORBIDDEN_PACKAGE}`);
      }
    }
    for (const field of bundledDependencyFields) {
      if (Array.isArray(json[field]) && json[field].includes(FORBIDDEN_PACKAGE)) {
        hits.push(`${relative} ${field} 不得捆绑 ${FORBIDDEN_PACKAGE}`);
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
