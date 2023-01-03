import {
    describe,
    expect,
    it,
  } from "bun:test";
  
  describe("snapshot test", () => {
    it("test snaphot", () => {
        const a = expect("5").toMatchSnapshot()
        console.log(a)
    })
  });
  