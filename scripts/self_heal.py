import os
import re

def self_heal_js(file_path):
    with open(file_path, 'r') as f:
        content = f.read()

    # Pattern for unused catch variables: catch (err) { -> catch {
    # This is a safe ES2019+ transformation if 'err' is unused
    new_content = re.sub(r'catch\s*\(([^)]+)\)\s*{', r'catch {', content)
    
    # Placeholder for more complex unused variable removals
    # In a production DevOps environment, this would integrate with ESLint output
    
    if new_content != content:
        with open(file_path, 'w') as f:
            f.write(new_content)
        print(f"Self-healed: {file_path}")

if __name__ == "__main__":
    # Walk through the project and heal JS/MJS files
    for root, dirs, files in os.walk("."):
        # ⚡ Bolt Optimization: Mutate dirs in-place to prevent os.walk from traversing ignored dirs
        dirs[:] = [d for d in dirs if d not in ("node_modules", ".git")]
        for file in files:
            if file.endswith((".js", ".mjs")):
                self_heal_js(os.path.join(root, file))
