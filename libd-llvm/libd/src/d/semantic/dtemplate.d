module d.semantic.dtemplate;

import d.semantic.identifiable;
import d.semantic.semantic;

import d.ast.declaration;
import d.ast.dscope;
import d.ast.dtemplate;
import d.ast.expression;
import d.ast.type;

import d.location;

import std.algorithm;
import std.array;
import std.range;

final class TemplateInstancier {
	private SemanticPass pass;
	alias pass this;
	
	this(SemanticPass pass) {
		this.pass = pass;
	}
	
	auto instanciate(Location location, TemplateDeclaration tplDecl, TemplateArgument[] arguments) {
		tplDecl = cast(TemplateDeclaration) scheduler.require(tplDecl);
		
		Declaration[] argDecls;
		uint i = 0;
		
		// XXX: have to put array once again.
		assert(tplDecl.parameters.length == arguments.length);
		string id = arguments.map!(delegate string(TemplateArgument arg) {
			return visit(arg).apply!(delegate string(identified) {
				static if(is(typeof(identified) : Type)) {
					argDecls ~= new AliasDeclaration(arg.location, tplDecl.parameters[i++].name, identified);
					
					return "T" ~ pass.typeMangler.visit(identified);
				} else {
					assert(0, "Only type argument are supported.");
				}
			})();
		}).array().join();
		
		return tplDecl.instances.get(id, {
			import d.semantic.clone;
			auto clone = new ClonePass();
			auto members = tplDecl.declarations.map!(d => clone.visit(d)).array();
			
			auto oldManglePrefix = this.manglePrefix;
			scope(exit) this.manglePrefix = oldManglePrefix;
			
			pass.manglePrefix = tplDecl.mangle ~ "T" ~ id ~ "Z";
			
			auto oldLinkage = pass.linkage;
			scope(exit) pass.linkage = oldLinkage;
			
			pass.linkage = tplDecl.linkage;
			
			auto oldIsStatic = pass.isStatic;
			scope(exit) pass.isStatic = oldIsStatic;
			
			pass.isStatic = tplDecl.isStatic;
			
			auto instance = new TemplateInstance(location, arguments, argDecls ~ members);
			pass.scheduler.schedule(instance.repeat(1), i => visit(cast(TemplateInstance) i));
			
			return tplDecl.instances[id] = cast(TemplateInstance) pass.scheduler.require(instance, pass.Step.Populated);
		}());
	}
	
	auto visit(TemplateInstance instance) {
		// Update scope.
		auto oldScope = currentScope;
		scope(exit) currentScope = oldScope;
		
		currentScope = instance.dscope = new SymbolScope(instance, oldScope);
		
		// XXX: make template instance a symbol. Change the template mangling in the process.
		auto syms = cast(Symbol[]) pass.flatten(instance.declarations, instance);
		
		instance.declarations = cast(Declaration[]) pass.scheduler.require(syms);
		
		return scheduler.register(instance, instance, Step.Processed);
	}
	
	Identifiable visit(TemplateArgument arg) {
		return this.dispatch(arg);
	}
	
	Identifiable visit(TypeTemplateArgument arg) {
		return Identifiable(pass.visit(arg.type));
	}
	
	Identifiable visit(IdentifierTemplateArgument arg) {
		return pass.visit(arg.identifier);
		/+
		if(auto type = pass.visit(arg.argument.type)) {
			return Identifiable(type);
		} else if(auto expression = pass.visit(arg.argument.expression)) {
			return Identifiable(expression);
		}
		+/
		// assert(0, "Ambiguous can't be deambiguated.");
	}
}

