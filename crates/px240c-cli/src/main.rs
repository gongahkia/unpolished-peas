use clap::Parser;

#[derive(Debug, Parser)]
#[command(
    name = "px240c",
    version,
    about = "PX-240C Color Development Unit toolchain"
)]
struct Arguments {
    /// Print language and cartridge-format revisions.
    #[arg(long)]
    revisions: bool,
}

fn main() {
    let arguments = Arguments::parse();
    if arguments.revisions {
        println!(
            "{} cartridge-format/{} compiler/{}",
            pxcl_core::LANGUAGE_REVISION,
            pxcl_core::CARTRIDGE_FORMAT_REVISION,
            pxcl_core::compiler_version()
        );
    }
}
