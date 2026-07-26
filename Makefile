RUST_TARGETS = aarch64-apple-darwin
LIB = target/aarch64-apple-darwin/release/libphotoscore.a
BINDINGS_DIR = bindings
XCF = PhotosCore.xcframework

.PHONY: test-rust bindings xcframework dmg clean

test-rust:
	cargo test --workspace

# 1) build the static lib, 2) generate Swift bindings from the built lib.
# libphotoscore.a statically links two uniffi components (photoscore and its
# models dependency, which has its own uniffi::setup_scaffolding!()), so this
# one `generate --library` pass emits both: PhotosCore.swift/PhotosCoreFFI.h
# and models.swift/modelsFFI.h, each with its own <name>FFI.modulemap.
bindings:
	cargo build --release -p photoscore --target aarch64-apple-darwin
	cargo run --release -p photoscore --bin uniffi-bindgen -- \
		generate --library $(LIB) \
		--language swift --out-dir $(BINDINGS_DIR)
	awk '1;ENDFILE{print ""}' $(BINDINGS_DIR)/*FFI.modulemap > $(BINDINGS_DIR)/module.modulemap
	rm -f $(BINDINGS_DIR)/PhotosCoreFFI.modulemap $(BINDINGS_DIR)/modelsFFI.modulemap

# package the static lib + both header sets into an xcframework the app
# links. uniffi 0.29 emits one `module.modulemap`-worthy file per component
# (PhotosCoreFFI.modulemap, modelsFFI.modulemap); Clang only auto-discovers a
# file literally named module.modulemap in a headers dir, so the bindings
# step above concatenates both component modulemaps into a single umbrella
# module.modulemap (each keeps its own top-level `module NAME { header ... }`
# block, so `import PhotosCoreFFI` and `import modelsFFI` both resolve).
xcframework: bindings
	rm -rf $(XCF)
	xcodebuild -create-xcframework \
		-library $(LIB) \
		-headers $(BINDINGS_DIR) \
		-output $(XCF)

# Build a distributable dmg installer (Release .app + /Applications alias).
# Delegates to the packaging script, which rebuilds the xcframework first so
# the app never links a stale core. Output: dist/SynologyPhotos-<version>.dmg.
dmg:
	scripts/package/dmg.sh

clean:
	cargo clean && rm -rf $(BINDINGS_DIR) $(XCF) build dist
