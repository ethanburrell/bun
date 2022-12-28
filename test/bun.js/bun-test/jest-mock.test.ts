import {
    describe,
    it,
    expect,
    fn
  } from "bun:test";

  describe("test jest mock", () => {
    it("calling mock", () => {
      console.log(fn)
      console.log(fn())
      expect(fn).toBeTruthy()
      expect(fn()).toBeTruthy()
      const mockFunc = fn()
      console.log(mockFunc)
    })
  })
