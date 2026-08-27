#!/usr/bin/env node
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
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

function walk(dir, { includeNodeModules = false } = {}) {
  if (!existsSync(dir)) {
    return [];
  }
  const out = [];
  for (const entry of readdirSync(dir)) {
    if ((!includeNodeModules && entry === 'node_modules') || (entry.startsWith('.') && entry !== '.webpack')) {
      continue;
    }
    const full = path.join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      out.push(...walk(full, { includeNodeModules }));
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

  const opaqueArrayShape = () => ({ opaque: true, kinds: [] });

  const UNRESOLVABLE_TARGET = Object.freeze({});

  const dangerousShapeKind = (shape) => {
    if (!shape) return null;
    if (shape.opaque) return 'requirer';
    return shape.kinds.find((k) => k === 'factory' || k === 'requirer') ?? null;
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

  const staticIndexValue = (expr) => {
    const argument = unwrapExpr(expr);
    if (argument && ts.isNumericLiteral(argument) && Number.isInteger(Number(argument.text))) {
      return Number(argument.text);
    }
    if (
      argument &&
      ts.isPrefixUnaryExpression(argument) &&
      argument.operator === ts.SyntaxKind.MinusToken &&
      ts.isNumericLiteral(argument.operand) &&
      Number.isInteger(Number(argument.operand.text))
    ) {
      return -Number(argument.operand.text);
    }
    if (argument && ts.isStringLiteralLike(argument) && /^\d+$/.test(argument.text)) {
      return Number(argument.text);
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
      if (!shape?.opaque && shape?.kinds[index] !== null && shape?.kinds[index] !== undefined) {
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
      const access = staticMember(unwrapped.expression);
      if (access?.name === 'at' && unwrapped.arguments.length === 1) {
        const atIndex = staticIndexValue(unwrapped.arguments[0]);
        if (atIndex !== null) {
          const shape = shapeForValue(access.object);
          if (shape && !shape.opaque) {
            const resolved = atIndex >= 0 ? atIndex : shape.kinds.length + atIndex;
            if (
              resolved >= 0 &&
              resolved < shape.kinds.length &&
              shape.kinds[resolved] !== null &&
              shape.kinds[resolved] !== undefined
            ) {
              return shape.kinds[resolved];
            }
          }
          if (shape?.opaque) {
            const dangerous = dangerousShapeKind(shape);
            if (dangerous) return dangerous;
          }
        }
        if (atIndex === null) {
          const dangerous = dangerousShapeKind(shapeForValue(access.object));
          if (dangerous) return dangerous;
        }
      }
    }
    const member = staticMember(unwrapped);
    if (member) {
      const resolved = resolveObjectProperty(member.object, member.name);
      if (resolved?.kind !== null && resolved?.kind !== undefined) {
        return resolved.kind;
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
    if (!ts.isCallExpression(expr)) {
      return null;
    }
    const access = staticMember(expr.expression);
    if (access?.name !== 'call' && access?.name !== 'apply') {
      return null;
    }
    return classifyExpr(access.object) === 'factory' ? 'requirer' : null;
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
    if (exprs.length === 1) return shapeFromValue(exprs[0]);
    const shapes = exprs.map((e) => shapeFromValue(e));
    const anyOpaque = shapes.some((s) => s.opaque);
    if (shapes.every((s) => s.kinds.length === shapes[0].kinds.length)) {
      const mergedKinds = shapes[0].kinds.map((_, i) => {
        for (const s of shapes) {
          if (s.kinds[i] === 'factory' || s.kinds[i] === 'requirer') return s.kinds[i];
        }
        return null;
      });
      return { opaque: anyOpaque, kinds: mergedKinds };
    }
    return opaqueArrayShape();
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
  };

  const registerClassMethodReturns = (base, classNode) => {
    for (const member of classNode.members) {
      let funcNode = null;
      if (ts.isMethodDeclaration(member) || ts.isGetAccessorDeclaration(member)) {
        funcNode = member;
      } else if (
        ts.isPropertyDeclaration(member) &&
        isFunctionLikeNode(unwrapExpr(member.initializer))
      ) {
        funcNode = unwrapExpr(member.initializer);
      }
      if (!funcNode) continue;
      const name = propertyNameText(member.name);
      if (name === null) continue;
      const isStatic = member.modifiers?.some(
        (modifier) => modifier.kind === ts.SyntaxKind.StaticKeyword,
      );
      registerReturnFacts(isStatic ? `${base}.${name}` : `${base}.prototype.${name}`, funcNode);
    }
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
    const key = callableReferenceKey(callee);
    if (key !== null) {
      const stored = functionReturns.get(key);
      if (stored) return stored;
    }
    const access = staticMember(callee);
    if (access) {
      return callablePropertyReturnKind(resolveObjectProperty(access.object, access.name));
    }
    return null;
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
      if (factories.has(expr.text)) {
        return 'factory';
      }
      if (requirers.has(expr.text)) {
        return 'requirer';
      }
      return null;
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

  const classifyExpr = (expr) => {
    expr = unwrapExpr(expr);
    if (!expr) {
      return null;
    }
    if (ts.isIdentifier(expr)) {
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
      return { opaque: true, kinds: [] };
    }
    if (ts.isArrayLiteralExpression(unwrapped)) {
      const kinds = [];
      let opaque = false;
      for (const el of unwrapped.elements) {
        if (ts.isOmittedExpression(el)) {
          kinds.push(null);
          continue;
        }
        if (ts.isSpreadElement(el)) {
          const inner = shapeFromValue(el.expression, seen);
          opaque = opaque || inner.opaque;
          kinds.push(...inner.kinds);
          continue;
        }
        const kind = classifyExpr(el);
        if (kind === null) {
          opaque = true;
        }
        kinds.push(kind);
      }
      return { opaque, kinds };
    }
    const key = referenceKey(unwrapped);
    if (key !== null) {
      if (seen.has(key)) {
        return { opaque: true, kinds: [] };
      }
      seen.add(key);
      const stored = arrayShapes.get(key);
      if (stored) {
        return stored;
      }
      return { opaque: true, kinds: [] };
    }
    return { opaque: true, kinds: [] };
  };

  const shapeForValue = (valueExpr) => {
    const unwrapped = valueExpr ? unwrapExpr(valueExpr) : undefined;
    if (!unwrapped) {
      return undefined;
    }
    if (ts.isArrayLiteralExpression(unwrapped)) {
      return shapeFromValue(unwrapped);
    }
    if (ts.isCallExpression(unwrapped)) {
      const callee = unwrapExpr(unwrapped.expression);
      const funcKey = callableReferenceKey(callee);
      if (funcKey) return functionReturnShapes.get(funcKey);
      return undefined;
    }
    const key = referenceKey(unwrapped);
    return key === null ? undefined : arrayShapes.get(key);
  };

  const knownArrayShape = (valueExpr) => shapeForValue(valueExpr);

  const resolveObjectProperty = (valueExpr, key) => {
    const unwrapped = valueExpr ? unwrapExpr(valueExpr) : undefined;
    if (unwrapped && ts.isConditionalExpression(unwrapped)) {
      let fallback;
      for (const branch of [unwrapped.whenTrue, unwrapped.whenFalse]) {
        const resolved = resolveObjectProperty(branch, key);
        if (!resolved) continue;
        if (dangerousPropertyKind(resolved) !== null) return resolved;
        if (!fallback) fallback = resolved;
      }
      return fallback;
    }
    if (unwrapped && ts.isCallExpression(unwrapped)) {
      const callableKey = callableReferenceKey(unwrapped.expression);
      const returnExprs = callableKey === null ? undefined : functionReturnExprs.get(callableKey);
      let fallback;
      for (const returnExpr of returnExprs ?? []) {
        const resolved = resolveObjectProperty(returnExpr, key);
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
          const spread = resolveObjectProperty(property.expression, key);
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
    const propertyKey = callableMemberKey(unwrapped, key);
    if (propertyKey === null) {
      return undefined;
    }
    const shape = arrayShapes.get(propertyKey);
    const kind = valueKinds.get(propertyKey);
    return shape || kind || hasReturnFacts(propertyKey)
      ? { value: undefined, kind: kind ?? null, shape, callableKey: propertyKey }
      : undefined;
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
      storeValueKind(propertyBase, classifyExpr(propertyValue));
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
    }
  };

  const bindPattern = (name, inheritedKind, valueExpr, shapeOverride, callableKeyOverride) => {
    if (ts.isIdentifier(name)) {
      const kind = kindFromValue(valueExpr, inheritedKind);
      if (kind === 'factory') {
        factories.add(name.text);
      }
      if (kind === 'requirer') {
        requirers.add(name.text);
      }
      if (isMutatingMethodReference(valueExpr)) {
        mutatorAliases.add(name.text);
      }
      const shape = shapeOverride ?? knownArrayShape(valueExpr);
      if (shape) {
        storeArrayShape(name.text, shape);
      } else {
        const valueKey = referenceKey(valueExpr);
        if (
          kind !== 'factory' &&
          kind !== 'requirer' &&
          valueKey !== null &&
          !ts.isIdentifier(unwrapExpr(valueExpr))
        ) {
          const opaque = arrayShapes.get(valueKey) ?? opaqueArrayShape();
          storeArrayShape(valueKey, opaque);
          storeArrayShape(name.text, opaque);
        } else if (arrayShapes.has(name.text)) {
          storeArrayShape(name.text, opaqueArrayShape());
        }
      }
      const unwrappedValue = valueExpr ? unwrapExpr(valueExpr) : undefined;
      if (unwrappedValue && isFunctionLikeNode(unwrappedValue)) {
        registerReturnFacts(name.text, unwrappedValue);
      }
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
      const shape = shapeFromValue(valueExpr);
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

  const bindNode = (node) => {
    invalidateArrayMutation(node);
    registerFunctionReturn(node);
    if (ts.isVariableDeclaration(node) && node.initializer) {
      bindPattern(node.name, classifyExpr(node.initializer), node.initializer);
    }
    if (ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.EqualsToken) {
      const left = unwrapExpr(node.left);
      const leftKey = referenceKey(left);
      if (leftKey !== null && !ts.isIdentifier(left)) {
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
  let previous = '';
  const snapshot = () =>
    `${factories.size}|${requirers.size}|${JSON.stringify([...arrayShapes.entries()])}|${JSON.stringify(
      [...valueKinds.entries()],
    )}|${JSON.stringify([...mutatorAliases])}|${JSON.stringify([...stringValues.entries()])}|${JSON.stringify(
      [...functionReturns.entries()],
    )}|${JSON.stringify([...functionReturnShapes.entries()])}|${JSON.stringify([
      ...classInstances.entries(),
    ])}`;
  while (previous !== snapshot()) {
    previous = snapshot();
    bindNode(sourceFile);
  }

  const loads = [];
  const visit = (node) => {
    loads.push(...loadsFromNode(node, classifyCallee, staticStringValue, classifyExpr));
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
    break;
  }
  return expr;
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
  const testkitRoot = path.resolve(workspaceRoot, 'packages/testkit');
  const resolved = path.resolve(absolute);
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
