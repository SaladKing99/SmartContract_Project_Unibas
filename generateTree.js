const fs = require("fs");
const path = require("path");
const {
    getAddress,
    keccak256,
    solidityPacked,
    concat
} = require("ethers");

// 1. WoVe-approved student wallet list
const students = [
    { label: "Student 1", address: "0x1B1408Cd451e8D86a2bb65bF64863723E16F7DC9" },
    { label: "Student 2", address: "0xBe15Df5a52B2029DfD4dF9EDDf31a6f8A8027962" },
    { label: "Student 3", address: "0x08E6dFceA7f851bB466aDC0D34f626E6d846D096" },
    { label: "Student 4", address: "0xFb56c7d84Df2ee5Ed4bCd1e1b5778d20d14fd8A1" },
    { label: "Student 5", address: "0x1795c4740Ef85cC0ACD7E3F12375336d1ee5C49c" }
];

// 2. Validate and normalize addresses
if (students.length === 0) {
    throw new Error("At least one wallet is required.");
}

const normalizedStudents = students.map((student) => ({
    label: student.label,
    address: getAddress(student.address)
}));

const unique = new Set(normalizedStudents.map((s) => s.address.toLowerCase()));
if (unique.size !== normalizedStudents.length) {
    throw new Error("Duplicate wallet addresses found.");
}

// 3. Hash each wallet exactly as WoVeStudentRegistry.sol does:
//    keccak256(abi.encodePacked(student))
const leaves = normalizedStudents.map((student) =>
    keccak256(solidityPacked(["address"], [student.address]))
);

// 4. Hash pairs in sorted order (matches OpenZeppelin MerkleProof.verify)
function hashPair(a, b) {
    const [left, right] = BigInt(a) < BigInt(b) ? [a, b] : [b, a];
    return keccak256(concat([left, right]));
}

// 5. Construct the Merkle tree
function buildTree(leaves) {
    const layers = [leaves];

    while (layers[layers.length - 1].length > 1) {
        const current = layers[layers.length - 1];
        const next = [];

        for (let i = 0; i < current.length; i += 2) {
            if (i + 1 < current.length) {
                next.push(hashPair(current[i], current[i + 1]));
            } else {
                // Carry the unpaired node to the next layer
                next.push(current[i]);
            }
        }

        layers.push(next);
    }

    return layers;
}

// 6. Generate an individual proof for a wallet
function getProof(layers, originalIndex) {
    const proof = [];
    let index = originalIndex;

    for (let level = 0; level < layers.length - 1; level++) {
        const current = layers[level];
        const siblingIndex = index % 2 === 0 ? index + 1 : index - 1;

        if (siblingIndex < current.length) {
            proof.push(current[siblingIndex]);
        }

        index = Math.floor(index / 2);
    }

    return proof;
}

// 7. Build the tree and format ready-to-copy-paste output
const layers = buildTree(leaves);
const root = layers[layers.length - 1][0];

// Capture a single run timestamp for both the file content and filename
const now = new Date();
const pad = (n) => String(n).padStart(2, "0");
const datePart = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
const timeForDisplay = `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;
const timeForFile = `${pad(now.getHours())}-${pad(now.getMinutes())}-${pad(now.getSeconds())}`;

const displayTimestamp = `${datePart} ${timeForDisplay}`;
const outputFileName = `merkle_output_${datePart}_${timeForFile}.txt`;

const lines = [
    "======================================================================",
    "FAIRHAUS — WOVE STUDENT REGISTRY MERKLE OUTPUT",
    `Generated: ${displayTimestamp}`,
    `Total Approved Students: ${normalizedStudents.length}`,
    "======================================================================",
    "",
    "MERKLE ROOT (Paste into WoVeStudentRegistry constructor / updateMerkleRoot):",
    root,
    "",
    "----------------------------------------------------------------------",
    "INDIVIDUAL STUDENT PROOFS (Ready to copy-paste into Remix enterRaffle):",
    "----------------------------------------------------------------------",
    ""
];

normalizedStudents.forEach((student, index) => {
    const proof = getProof(layers, index);
    lines.push(`${student.label} | ${student.address}`);
    lines.push(JSON.stringify(proof));
    lines.push("");
});

const outputText = lines.join("\n");

// 8. Save to a timestamped .txt file (Notepad-compatible) in the same folder
const outputPath = path.join(__dirname, outputFileName);
fs.writeFileSync(outputPath, outputText, "utf8");

// Also print to terminal for quick viewing
console.log(outputText);
console.log(`Saved ready-to-copy output to: ${outputPath}`);