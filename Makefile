RUST_TARGETS = aarch64-apple-darwin
LIB = target/aarch64-apple-darwin/release/libphotoscore.a
BINDINGS_DIR = bindings
XCF = PhotosCore.xcframework

.PHONY: test-rust bindings xcframework clean

test-rust:
	cargo test --workspace

# 1) build the static lib, 2) generate Swift bindings from the built lib
bindings:
	cargo build --release -p photoscore --target aarch64-apple-darwin
	cargo run --release -p photoscore --bin uniffi-bindgen -- \
		generate --library $(LIB) \
		--language swift --out-dir $(BINDINGS_DIR)
	mv $(BINDINGS_DIR)/PhotosCoreFFI.modulemap $(BINDINGS_DIR)/module.modulemap 2>/dev/null || true

# package the static lib + headers into an xcframework the app links
xcframework: bindings
	rm -rf $(XCF)
	xcodebuild -create-xcframework \
		-library $(LIB) \
		-headers $(BINDINGS_DIR) \
		-output $(XCF)

clean:
	cargo clean && rm -rf $(BINDINGS_DIR) $(XCF)
